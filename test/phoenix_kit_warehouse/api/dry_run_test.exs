defmodule PhoenixKitWarehouse.API.DryRunTest do
  @moduledoc """
  A write handler called with `dry_run?: true` has no side effects and
  previews exactly what a real call would do; the fingerprint covers the
  current values of the fields the operation touches.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKit.Activity.Entry
  alias PhoenixKitWarehouse.API.Write
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.Test.ApiOrders, as: Orders

  setup do
    %{locations: [first, second]} = warehouses!(2)
    catalogue = shop_catalogue!()
    user = user!()

    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :source_kinds) end)

    %{
      first: first,
      second: second,
      a: item!(catalogue),
      b: item!(catalogue),
      ctx: ctx(user),
      dry: ctx(user, %{dry_run?: true})
    }
  end

  defp line(item, quantity), do: %{"ref" => %{"id" => item.uuid}, "quantity" => quantity}

  defp footprint do
    %{rows: seqs} =
      Repo.query!("""
      SELECT last_value, is_called FROM phoenix_kit_warehouse_goods_receipts_number_seq
      UNION ALL SELECT last_value, is_called FROM phoenix_kit_warehouse_goods_issues_number_seq
      UNION ALL SELECT last_value, is_called FROM phoenix_kit_warehouse_inventory_documents_number_seq
      """)

    %{
      receipts: Repo.aggregate(GoodsReceipt, :count),
      issues: Repo.aggregate(GoodsIssue, :count),
      inventories: Repo.aggregate(InventoryDocument, :count),
      stock:
        Repo.all(
          from(s in Stock,
            select: {s.item_uuid, s.location_uuid, s.quantity},
            order_by: [s.item_uuid, s.location_uuid]
          )
        ),
      activity: Repo.aggregate(from(e in Entry, where: like(e.action, "warehouse.%")), :count),
      sequences: seqs
    }
  end

  defp tools(%{a: a, b: b}) do
    lines = [line(a, "1"), line(b, "2")]

    [
      {:receive_stock, %{"lines" => lines}},
      {:set_stock, %{"lines" => lines}},
      {:issue_stock, %{"reason" => "sale", "lines" => lines}}
    ]
  end

  test "each tool previews without a single side effect",
       %{first: first, a: a, b: b, dry: dry} = context do
    seed!(a.uuid, "10", first.uuid)
    seed!(b.uuid, "10", first.uuid)
    before = footprint()

    for {tool, input} <- tools(context) do
      assert {:preview, %{"status" => "would_post", "document" => document, "results" => [_, _]},
              fingerprint} = apply(Write, tool, [input, dry])

      assert document["id"] == nil and document["number"] == nil
      assert document["location_id"] == first.uuid
      assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    end

    assert footprint() == before
  end

  test "the preview shows the same from/to as the real call",
       %{first: first, a: a, ctx: ctx, dry: dry} = context do
    seed!(a.uuid, "10", first.uuid)

    for {tool, input} <- tools(context) do
      {:preview, %{"results" => preview_results}, _fingerprint} = apply(Write, tool, [input, dry])
      {:ok, %{"results" => real_results}} = apply(Write, tool, [input, ctx])

      strip = fn results -> Enum.map(results, &Map.take(&1, ["id", "action", "from", "to"])) end
      assert strip.(preview_results) == strip.(real_results), "#{tool}"
    end
  end

  test "the fingerprint is stable and changes when a touched quantity changes",
       %{first: first, a: a, b: b, dry: dry} do
    seed!(a.uuid, "10", first.uuid)
    input = %{"lines" => [line(a, "1"), line(b, "2")]}

    {:preview, _, one} = Write.receive_stock(input, dry)
    {:preview, _, same} = Write.receive_stock(input, dry)
    assert one == same

    seed!(a.uuid, "11", first.uuid)
    {:preview, _, changed} = Write.receive_stock(input, dry)
    assert changed != one

    other = %{"lines" => [line(a, "1")]}
    {:preview, _, narrower} = Write.receive_stock(other, dry)
    assert narrower != changed
  end

  test "the fingerprint covers the warehouse, also when the stock is the same in both",
       %{first: first, second: second, a: a, dry: dry} do
    input = %{"lines" => [line(a, "1")]}

    {:preview, _, in_default} = Write.receive_stock(input, dry)

    {:preview, _, in_first} =
      Write.receive_stock(Map.put(input, "location_id", first.uuid), dry)

    {:preview, _, in_second} =
      Write.receive_stock(Map.put(input, "location_id", second.uuid), dry)

    assert in_default == in_first
    assert in_second != in_first

    # The default warehouse moves between the preview and the confirmation.
    PhoenixKitWarehouse.StockLedger.set_default_location_uuid(second.uuid)
    {:preview, _, moved} = Write.receive_stock(input, dry)
    assert moved == in_second
    assert moved != in_default
  end

  test "the fingerprint covers the kind of document", %{a: a, dry: dry} do
    input = %{"lines" => [line(a, "1")]}

    {:preview, _, receipt} = Write.receive_stock(input, dry)
    {:preview, _, stocktake} = Write.set_stock(input, dry)

    assert receipt != stocktake
  end

  test "an issue preview reports every short line like the real call and writes nothing",
       %{first: first, a: a, b: b, ctx: ctx, dry: dry} do
    seed!(a.uuid, "1", first.uuid)
    input = %{"reason" => "sale", "lines" => [line(a, "3"), line(b, "1")]}
    before = footprint()

    assert {:error, :insufficient_stock, _message, %{lines: dry_lines}} =
             Write.issue_stock(input, dry)

    assert {:error, :insufficient_stock, _message, %{lines: real_lines}} =
             Write.issue_stock(input, ctx)

    assert dry_lines == real_lines
    assert length(dry_lines) == 2
    assert footprint() == before
  end

  test "a preview refuses the same bad requests as a real call", %{a: a, dry: dry} do
    input = %{
      "lines" => [
        line(a, "1"),
        line(a, "1"),
        %{"ref" => %{"id" => Ecto.UUID.generate()}, "quantity" => "-1"}
      ]
    }

    assert {:error, :validation_failed, _message, %{errors: errors, posted: false}} =
             Write.receive_stock(input, dry)

    assert Enum.sort(Enum.map(errors, & &1.path)) ==
             ["lines[1]", "lines[2].quantity", "lines[2].ref"]
  end

  test "a known external_ref previews as would_skip, pointing at the existing document",
       %{a: a, ctx: ctx, dry: dry} do
    input = %{"external_ref" => "DRY-1", "lines" => [line(a, "1")]}
    {:ok, posted} = Write.receive_stock(input, ctx)
    before = footprint()

    assert {:preview,
            %{
              "status" => "would_skip",
              "document" => document,
              "results" => [%{"action" => "skipped"}]
            }, _} = Write.receive_stock(input, dry)

    assert document["id"] == posted["document"]["id"]
    assert document["number"] == posted["document"]["number"]
    assert footprint() == before
  end

  test "a would_skip preview names the document in its fingerprint", %{a: a, ctx: ctx, dry: dry} do
    first = %{"external_ref" => "DRY-FP-1", "lines" => [line(a, "1")]}
    second = %{"external_ref" => "DRY-FP-2", "lines" => [line(a, "1")]}
    {:ok, _} = Write.receive_stock(first, ctx)
    {:ok, _} = Write.receive_stock(second, ctx)

    {:preview, %{"status" => "would_skip"}, one} = Write.receive_stock(first, dry)
    {:preview, %{"status" => "would_skip"}, same} = Write.receive_stock(first, dry)
    {:preview, %{"status" => "would_skip"}, other} = Write.receive_stock(second, dry)

    {:preview, %{"status" => "would_post"}, fresh} =
      Write.receive_stock(%{"lines" => [line(a, "1")]}, dry)

    assert one == same
    assert one != other
    assert one != fresh
  end

  test "a would_skip preview carries the effects of the retry; a different one is the error",
       %{a: a, b: b, ctx: ctx, dry: dry} do
    input = %{"external_ref" => "DRY-FX-1", "lines" => [line(a, "1")]}
    {:ok, _} = Write.receive_stock(input, ctx)

    assert {:preview, preview, _} = Write.receive_stock(input, dry)
    refute Map.has_key?(preview, "effects")

    other = Map.put(input, "lines", [line(a, "2")])

    assert {:error, :validation_failed, _, %{errors: [%{code: code}], posted: false}} =
             Write.receive_stock(other, dry)

    assert code == "external_ref_lines_differ"

    third = Map.put(input, "lines", [line(a, "1"), line(b, "1")])

    assert {:error, :validation_failed, _, %{errors: [%{code: code}], posted: false}} =
             Write.receive_stock(third, dry)

    assert code == "external_ref_lines_differ"

    {:ok, _} = PhoenixKitCatalogue.Catalogue.trash_item(a)
    assert {:preview, %{"effects" => [%{"code" => code}]}, _} = Write.receive_stock(input, dry)
    assert code == "external_ref_lines_unverified"
  end

  test "a shop_order basis is checked but not attached", %{first: first, a: a, dry: dry} do
    seed!(a.uuid, "5", first.uuid)
    order = Ecto.UUID.generate()
    Orders.put(order, "Order #7")
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [Orders.kind()])
    before = footprint()

    input = %{
      "reason" => "sale",
      "source" => %{"kind" => "shop_order", "id" => order},
      "lines" => [line(a, "1")]
    }

    assert {:preview, %{"status" => "would_post"}, _} = Write.issue_stock(input, dry)
    assert footprint() == before

    unknown = put_in(input, ["source", "id"], Ecto.UUID.generate())

    assert {:error, :validation_failed, _message, %{errors: [%{path: "source.id"}]}} =
             Write.issue_stock(unknown, dry)
  end
end
