defmodule PhoenixKitWarehouse.API.SetStockTest do
  @moduledoc """
  `warehouse.set_stock`: a stocktake document that sets the listed items to
  absolute quantities, with the exact prior quantity as `from`.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKit.Activity.Entry
  alias PhoenixKitWarehouse.API.Write
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.StockLedger

  setup do
    %{locations: [first, second]} = warehouses!(2)
    catalogue = shop_catalogue!()
    user = user!()

    %{
      first: first,
      second: second,
      a: item!(catalogue),
      b: item!(catalogue),
      c: item!(catalogue),
      user: user,
      ctx: ctx(user)
    }
  end

  defp line(item, quantity), do: %{"ref" => %{"id" => item.uuid}, "quantity" => quantity}

  defp set!(input, ctx) do
    assert {:ok, body} = Write.set_stock(input, ctx)
    body
  end

  test "sets the listed items and leaves every other stock row alone; from is the quantity before",
       %{
         first: first,
         a: a,
         b: b,
         c: c,
         user: user,
         ctx: ctx
       } do
    seed!(a.uuid, "10", first.uuid)
    seed!(c.uuid, "9", first.uuid)

    body = set!(%{"lines" => [line(a, "7"), line(b, 4)], "note" => "year end"}, ctx)

    assert body["status"] == "posted"
    assert %{"type" => "inventory", "number" => number} = body["document"]
    assert is_integer(number)

    assert [
             %{"id" => a_id, "action" => "updated", "from" => "10", "to" => "7"},
             %{"id" => b_id, "action" => "updated", "from" => "0", "to" => "4"}
           ] = body["results"]

    assert {a_id, b_id} == {a.uuid, b.uuid}

    assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(7))
    assert Decimal.equal?(quantity(b.uuid, first.uuid), Decimal.new(4))
    assert Decimal.equal?(quantity(c.uuid, first.uuid), Decimal.new(9))

    document = Repo.get!(InventoryDocument, body["document"]["id"])
    assert document.status == "posted" and document.performed_by_uuid == user.uuid
    assert document.note == "year end"
  end

  test "zero is a valid count; a count equal to the stock is unchanged", %{
    first: first,
    a: a,
    b: b,
    ctx: ctx
  } do
    seed!(a.uuid, "5", first.uuid)
    seed!(b.uuid, "3", first.uuid)

    body = set!(%{"lines" => [line(a, "0"), line(b, "3")]}, ctx)

    assert [
             %{"action" => "updated", "from" => "5", "to" => "0"},
             %{"action" => "unchanged", "from" => "3", "to" => "3"}
           ] =
             body["results"]

    assert body["summary"] == %{"updated" => 1, "unchanged" => 1}
    assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(0))
  end

  defp number_sequence do
    %{rows: [state]} =
      Repo.query!(
        "SELECT last_value, is_called FROM phoenix_kit_warehouse_inventory_documents_number_seq"
      )

    state
  end

  describe "a count that changes nothing" do
    test "creates no document, burns no number and answers unchanged", %{
      first: first,
      a: a,
      b: b,
      ctx: ctx
    } do
      seed!(a.uuid, "5", first.uuid)
      seed!(b.uuid, "3", first.uuid)
      documents_before = Repo.aggregate(InventoryDocument, :count)
      sequence_before = number_sequence()

      body = set!(%{"external_ref" => "SAME-1", "lines" => [line(a, "5"), line(b, 3)]}, ctx)

      assert body["status"] == "unchanged"
      refute Map.has_key?(body, "document")

      assert [
               %{"action" => "unchanged", "from" => "5", "to" => "5"},
               %{"action" => "unchanged", "from" => "3", "to" => "3"}
             ] = body["results"]

      assert body["summary"] == %{"unchanged" => 2}
      assert Repo.aggregate(InventoryDocument, :count) == documents_before

      assert number_sequence() == sequence_before

      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(5))
    end

    test "a missing stock row counted as zero is unchanged and is not created", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      body = set!(%{"lines" => [line(a, "0")]}, ctx)

      assert body["status"] == "unchanged"
      assert StockLedger.stock_for_items_at_location([a.uuid], first.uuid) == []
    end

    test "one changed line posts the whole document, unchanged lines included", %{
      first: first,
      a: a,
      b: b,
      ctx: ctx
    } do
      seed!(a.uuid, "5", first.uuid)
      seed!(b.uuid, "3", first.uuid)

      body = set!(%{"lines" => [line(a, "5"), line(b, "4")]}, ctx)

      assert body["status"] == "posted"
      assert body["summary"] == %{"unchanged" => 1, "updated" => 1}

      document = Repo.get!(InventoryDocument, body["document"]["id"])
      assert length(document.lines) == 2
    end

    test "a repeated reference of a posted count is still skipped", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      input = %{"external_ref" => "COUNT-SAME", "lines" => [line(a, "6")]}
      set!(input, ctx)

      assert set!(input, ctx)["status"] == "skipped"
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(6))
    end

    test "the preview says unchanged and writes nothing", %{first: first, a: a, ctx: ctx} do
      seed!(a.uuid, "5", first.uuid)

      assert {:preview, %{"status" => "unchanged", "results" => [%{"action" => "unchanged"}]}, _} =
               Write.set_stock(%{"lines" => [line(a, "5")]}, Map.put(ctx, :dry_run?, true))
    end
  end

  test "a different location is counted separately", %{
    first: first,
    second: second,
    a: a,
    ctx: ctx
  } do
    seed!(a.uuid, "5", first.uuid)

    body = set!(%{"location_id" => second.uuid, "lines" => [line(a, "2")]}, ctx)

    assert [%{"from" => "0", "to" => "2"}] = body["results"]
    assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(5))
    assert Decimal.equal?(quantity(a.uuid, second.uuid), Decimal.new(2))
  end

  test "external_ref: a retry is skipped and does not reset stock that moved in between", %{
    first: first,
    a: a,
    ctx: ctx
  } do
    input = %{"external_ref" => "COUNT-2026", "lines" => [line(a, "6")]}
    set!(input, ctx)
    seed!(a.uuid, "50", first.uuid)

    again = set!(input, ctx)

    assert again["status"] == "skipped"
    assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(50))
  end

  test "a reference reused with another count is refused; stock does not move", %{
    first: first,
    a: a,
    ctx: ctx
  } do
    set!(%{"external_ref" => "COUNT-2027", "lines" => [line(a, "6")]}, ctx)

    assert {:error, :validation_failed, _message, context} =
             Write.set_stock(%{"external_ref" => "COUNT-2027", "lines" => [line(a, "60")]}, ctx)

    assert [%{path: "lines", code: "external_ref_lines_differ"}] = context.errors
    assert context.posted == false
    assert context.document["type"] == "inventory"
    assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(6))
  end

  test "refusals are atomic: unknown product, duplicate, negative, bad location", %{
    first: first,
    a: a,
    ctx: ctx
  } do
    seed!(a.uuid, "5", first.uuid)
    documents_before = Repo.aggregate(InventoryDocument, :count)

    assert {:error, :validation_failed, _message, %{errors: errors, posted: false}} =
             Write.set_stock(
               %{
                 "location_id" => "nope",
                 "lines" => [
                   line(a, "-1"),
                   %{"ref" => %{"id" => Ecto.UUID.generate()}, "quantity" => "1"},
                   line(a, "2")
                 ]
               },
               ctx
             )

    assert Enum.sort(Enum.map(errors, & &1.path)) ==
             Enum.sort(["location_id", "lines[0].quantity", "lines[1].ref", "lines[2]"])

    assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(5))
    assert Repo.aggregate(InventoryDocument, :count) == documents_before
  end

  test "the Activity entry is the existing inventory action with the API metadata", %{
    first: first,
    a: a,
    ctx: ctx
  } do
    body = set!(%{"external_ref" => "ACT-1", "lines" => [line(a, "1")]}, ctx)

    entry =
      Repo.one!(
        from(e in Entry,
          where:
            e.action == "warehouse.inventory.posted" and
              e.resource_uuid == ^body["document"]["id"]
        )
      )

    assert %{
             "via" => "api",
             "tool" => "warehouse.set_stock",
             "lines" => 1,
             "external_ref" => "ACT-1",
             "location_uuid" => location_uuid
           } = entry.metadata

    assert location_uuid == first.uuid
  end
end
