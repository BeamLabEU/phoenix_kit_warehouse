defmodule PhoenixKitWarehouse.API.RetryBasisTest do
  @moduledoc """
  A repeated `external_ref` is answered `skipped` from the posted document.
  Only a request that matches that document passes for a plain retry: a
  warehouse, catalogue, reason or order that differs is reported in the
  answer, and a malformed source is refused as in a first call.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKitWarehouse.API.Write
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.Test.ApiOrders, as: Orders

  setup do
    %{locations: [first, second]} = warehouses!(2)
    catalogue = shop_catalogue!()
    user = user!()

    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :source_kinds) end)

    %{
      first: first,
      second: second,
      catalogue: catalogue,
      a: item!(catalogue),
      ctx: ctx(user),
      dry: ctx(user, %{dry_run?: true})
    }
  end

  defp line(item, quantity), do: %{"ref" => %{"id" => item.uuid}, "quantity" => quantity}

  defp effects({:ok, _body}), do: []
  defp effects({:ok, _body, effects}), do: effects
  defp effects({:preview, %{"effects" => effects}, _fingerprint}), do: effects
  defp effects({:preview, _body, _fingerprint}), do: []

  defp codes(result), do: result |> effects() |> Enum.map(& &1["code"])

  defp body({:ok, body}), do: body
  defp body({:ok, body, _effects}), do: body
  defp body({:preview, body, _fingerprint}), do: body

  defp register_orders(uuid) do
    Orders.put(uuid, "Order #1001")
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [Orders.kind()])
    uuid
  end

  describe "the warehouse" do
    test "a receipt reference reused for another warehouse says so and moves no stock", %{
      first: first,
      second: second,
      a: a,
      ctx: ctx
    } do
      input = %{"external_ref" => "RB-LOC-1", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.receive_stock(input, ctx)

      result = Write.receive_stock(Map.put(input, "location_id", second.uuid), ctx)

      assert {:ok, %{"status" => "skipped", "document" => %{"location_id" => location}}, [effect]} =
               result

      assert location == first.uuid
      assert effect["code"] == "external_ref_basis_differs"
      assert effect["message"] =~ "location_id"
      assert Decimal.equal?(quantity(a.uuid, second.uuid), Decimal.new(0))
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(5))
    end

    test "a stocktake reference reused for another warehouse says so", %{
      second: second,
      a: a,
      ctx: ctx
    } do
      input = %{"external_ref" => "RB-LOC-2", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.set_stock(input, ctx)

      result = Write.set_stock(Map.put(input, "location_id", second.uuid), ctx)

      assert {:ok, %{"status" => "skipped"}, [%{"code" => "external_ref_basis_differs"}]} = result
      assert Decimal.equal?(quantity(a.uuid, second.uuid), Decimal.new(0))
    end

    test "a location that does not exist is reported, not refused, on a retry", %{
      a: a,
      ctx: ctx
    } do
      input = %{"external_ref" => "RB-LOC-3", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.receive_stock(input, ctx)

      for bad <- [Ecto.UUID.generate(), "nope", 5] do
        result = Write.receive_stock(Map.put(input, "location_id", bad), ctx)
        assert {:ok, %{"status" => "skipped"}, [_effect]} = result
        assert codes(result) == ["external_ref_basis_differs"]
      end
    end

    test "the same warehouse, named or defaulted, is a plain retry even after the default moved",
         %{first: first, second: second, a: a, ctx: ctx} do
      input = %{"external_ref" => "RB-LOC-4", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.receive_stock(input, ctx)

      assert {:ok, %{"status" => "skipped"}} =
               Write.receive_stock(Map.put(input, "location_id", first.uuid), ctx)

      assert {:ok, %{"status" => "skipped"}} =
               Write.receive_stock(Map.put(input, "location_id", String.upcase(first.uuid)), ctx)

      PhoenixKitWarehouse.StockLedger.set_default_location_uuid(second.uuid)
      assert {:ok, %{"status" => "skipped"}} = Write.receive_stock(input, ctx)
    end

    test "a preview of the retry carries the same effect", %{
      second: second,
      a: a,
      ctx: ctx,
      dry: dry
    } do
      input = %{"external_ref" => "RB-LOC-5", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.receive_stock(input, ctx)

      result = Write.receive_stock(Map.put(input, "location_id", second.uuid), dry)

      assert %{"status" => "would_skip"} = body(result)
      assert codes(result) == ["external_ref_basis_differs"]
    end
  end

  describe "the catalogue" do
    test "a reference reused with another catalogue says so", %{a: a, ctx: ctx} do
      input = %{"external_ref" => "RB-CAT-1", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.receive_stock(input, ctx)
      other = catalogue!()

      assert {:ok, %{"status" => "skipped"}} =
               Write.receive_stock(Map.put(input, "catalogue_id", a.catalogue_uuid), ctx)

      result = Write.receive_stock(Map.put(input, "catalogue_id", other.uuid), ctx)
      assert "external_ref_basis_differs" in codes(result)

      result = Write.receive_stock(Map.put(input, "catalogue_id", Ecto.UUID.generate()), ctx)
      assert "external_ref_basis_differs" in codes(result)
    end
  end

  describe "the reason of an issue" do
    test "a reference reused with another reason says so and writes off nothing more", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "10", first.uuid)
      input = %{"external_ref" => "RB-REASON-1", "reason" => "sale", "lines" => [line(a, "2")]}
      assert {:ok, %{"status" => "posted"}} = Write.issue_stock(input, ctx)

      assert {:ok, %{"status" => "skipped"}} = Write.issue_stock(input, ctx)

      result = Write.issue_stock(Map.put(input, "reason", "damage"), ctx)

      assert {:ok, %{"status" => "skipped", "document" => %{"reason" => "sale"}}, [effect]} =
               result

      assert effect["code"] == "external_ref_basis_differs"
      assert effect["message"] =~ "reason"
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(8))
    end
  end

  describe "the order of an issue" do
    setup %{first: first, a: a} do
      seed!(a.uuid, "10", first.uuid)
      %{order: register_orders(Ecto.UUID.generate())}
    end

    defp crashed_issue(a, ctx) do
      # The state after a crash between the posting and the link to the order.
      input = %{"external_ref" => "RB-ORDER-1", "reason" => "sale", "lines" => [line(a, "1")]}

      assert {:ok, %{"status" => "posted", "document" => %{"id" => id}}} =
               Write.issue_stock(input, ctx)

      {input, id}
    end

    test "a retry that names an order the document is not linked to says so", %{
      a: a,
      ctx: ctx,
      order: order
    } do
      {input, id} = crashed_issue(a, ctx)
      retry = Map.put(input, "source", %{"kind" => "shop_order", "id" => order})

      result = Write.issue_stock(retry, ctx)

      assert {:ok, %{"status" => "skipped"}, [effect]} = result
      assert effect["code"] == "source_ref_not_attached"
      assert Repo.get!(GoodsIssue, id).source_refs == []
    end

    test "a retry that names another order than the linked one says so", %{
      a: a,
      first: first,
      ctx: ctx,
      order: order
    } do
      input = %{
        "external_ref" => "RB-ORDER-2",
        "reason" => "sale",
        "source" => %{"kind" => "shop_order", "id" => order},
        "lines" => [line(a, "1")]
      }

      assert {:ok, %{"status" => "posted"}} = Write.issue_stock(input, ctx)
      assert {:ok, %{"status" => "skipped"}} = Write.issue_stock(input, ctx)

      other = register_orders(Ecto.UUID.generate())
      retry = put_in(input, ["source", "id"], other)

      assert {:ok, %{"status" => "skipped"}, [%{"code" => "source_ref_not_attached"}]} =
               Write.issue_stock(retry, ctx)

      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(9))
    end

    test "a retry of an issue with no order needs no effect", %{a: a, ctx: ctx} do
      {input, _id} = crashed_issue(a, ctx)
      assert {:ok, %{"status" => "skipped"}} = Write.issue_stock(input, ctx)
    end
  end

  describe "a source that is not valid" do
    setup %{first: first, a: a, ctx: ctx} do
      seed!(a.uuid, "10", first.uuid)
      order = register_orders(Ecto.UUID.generate())

      assert {:ok, %{"status" => "posted"}} =
               Write.issue_stock(
                 %{
                   "reason" => "sale",
                   "source" => %{"kind" => "external", "ref" => "RB-SRC-1"},
                   "lines" => [line(a, "1")]
                 },
                 ctx
               )

      %{order: order}
    end

    test "is refused on a retry as in a first call, not answered skipped", %{
      a: a,
      ctx: ctx,
      order: order
    } do
      lines = [line(a, "1")]

      # An external source with a key it does not have: it names the same
      # reference as the posted document, and still is not a retry.
      extra = %{"kind" => "external", "ref" => "RB-SRC-1", "id" => order}

      assert {:error, :validation_failed, _message, %{errors: [%{path: "source"}], posted: false}} =
               Write.issue_stock(%{"reason" => "sale", "source" => extra, "lines" => lines}, ctx)

      # A shop order source that is malformed, with the reference of the posted document.
      for {source, path} <- [
            {%{"kind" => "shop_order", "id" => "not-a-uuid"}, "source.id"},
            {%{"kind" => "shop_order", "id" => order, "ref" => "RB-SRC-1"}, "source"}
          ] do
        input = %{
          "external_ref" => "RB-SRC-1",
          "reason" => "sale",
          "source" => source,
          "lines" => lines
        }

        assert {:error, :validation_failed, _message, %{errors: [%{path: ^path}], posted: false}} =
                 Write.issue_stock(input, ctx)
      end
    end
  end
end
