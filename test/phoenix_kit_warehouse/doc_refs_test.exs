defmodule PhoenixKitWarehouse.DocRefsTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.DocRefs
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Test.FakeOrderSources
  alias PhoenixKitCatalogue.Catalogue

  setup do
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
      FakeOrderSources.order_kind(),
      FakeOrderSources.sub_order_kind()
    ])

    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :source_kinds) end)
    :ok
  end

  @default_location "00000000-0000-0000-0000-000000000001"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_internal_order! do
    {:ok, order} =
      InternalOrders.create_internal_order(%{
        location_uuid: @default_location,
        lines: []
      })

    order
  end

  defp create_supplier! do
    {:ok, s} =
      Catalogue.create_supplier(%{
        name: "Supplier #{System.unique_integer([:positive])}",
        status: "active"
      })

    s
  end

  defp create_supplier_order!(supplier) do
    {:ok, so} =
      SupplierOrders.create_supplier_order(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @default_location,
        lines: []
      })

    so
  end

  defp create_goods_receipt!(supplier) do
    {:ok, gr} =
      GoodsReceipts.create_goods_receipt(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @default_location,
        lines: []
      })

    gr
  end

  defp create_goods_issue! do
    io = create_internal_order!()

    {:ok, gi} =
      GoodsIssues.create_goods_issue(%{
        internal_order_uuid: io.uuid,
        location_uuid: @default_location,
        lines: []
      })

    gi
  end

  defp create_sub_order! do
    parent_num = System.unique_integer([:positive])
    sub_num = System.unique_integer([:positive])

    parent =
      FakeOrderSources.put_order(%{
        uuid: Ecto.UUID.generate(),
        label: "##{parent_num}",
        lines: [],
        data: %{"order_number" => parent_num}
      })

    sub =
      FakeOrderSources.put_sub_order(%{
        uuid: Ecto.UUID.generate(),
        label: "##{parent_num}-#{sub_num}",
        lines: [],
        data: %{"sub_order_number" => sub_num}
      })

    {parent, sub}
  end

  # ---------------------------------------------------------------------------
  # internal_order_ref
  # ---------------------------------------------------------------------------

  describe "internal_order_ref/1" do
    test "returns nil for nil" do
      assert DocRefs.internal_order_ref(nil) == nil
    end

    test "returns nil for unknown uuid" do
      assert DocRefs.internal_order_ref(Ecto.UUID.generate()) == nil
    end

    test "returns a ref map with #IO-N label and path" do
      order = create_internal_order!()
      ref = DocRefs.internal_order_ref(order.uuid)

      assert ref != nil
      assert ref.label == "#IO-#{order.number}"
      assert String.contains?(ref.path, "/internal-orders/#{order.uuid}")
    end
  end

  # ---------------------------------------------------------------------------
  # internal_order_refs/1 (batch)
  # ---------------------------------------------------------------------------

  describe "internal_order_refs/1" do
    test "returns empty map for empty list" do
      assert DocRefs.internal_order_refs([]) == %{}
    end

    test "returns map with ref for known uuids" do
      o1 = create_internal_order!()
      o2 = create_internal_order!()

      refs = DocRefs.internal_order_refs([o1.uuid, o2.uuid])

      assert map_size(refs) == 2
      assert refs[o1.uuid].label == "#IO-#{o1.number}"
      assert refs[o2.uuid].label == "#IO-#{o2.number}"
    end

    test "omits nil and unknown uuids" do
      refs = DocRefs.internal_order_refs([nil, Ecto.UUID.generate()])
      assert refs == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # supplier_order_ref
  # ---------------------------------------------------------------------------

  describe "supplier_order_ref/1" do
    test "returns nil for nil" do
      assert DocRefs.supplier_order_ref(nil) == nil
    end

    test "returns ref with #SO-N label" do
      supplier = create_supplier!()
      so = create_supplier_order!(supplier)
      ref = DocRefs.supplier_order_ref(so.uuid)

      assert ref.label == "#SO-#{so.number}"
      assert String.contains?(ref.path, "/supplier-orders/#{so.uuid}")
    end
  end

  # ---------------------------------------------------------------------------
  # goods_receipt_ref
  # ---------------------------------------------------------------------------

  describe "goods_receipt_ref/1" do
    test "returns nil for nil" do
      assert DocRefs.goods_receipt_ref(nil) == nil
    end

    test "returns ref with #GR-N label" do
      supplier = create_supplier!()
      gr = create_goods_receipt!(supplier)
      ref = DocRefs.goods_receipt_ref(gr.uuid)

      assert ref.label == "#GR-#{gr.number}"
      assert String.contains?(ref.path, "/goods-receipts/#{gr.uuid}")
    end
  end

  # ---------------------------------------------------------------------------
  # goods_issue_ref
  # ---------------------------------------------------------------------------

  describe "goods_issue_ref/1" do
    test "returns nil for nil" do
      assert DocRefs.goods_issue_ref(nil) == nil
    end

    test "returns ref with #GI-N label" do
      gi = create_goods_issue!()
      ref = DocRefs.goods_issue_ref(gi.uuid)

      assert ref.label == "#GI-#{gi.number}"
      assert String.contains?(ref.path, "/goods-issues/#{gi.uuid}")
    end
  end

  # ---------------------------------------------------------------------------
  # sub_order_ref
  # ---------------------------------------------------------------------------

  describe "sub_order_ref/1" do
    test "returns nil for nil" do
      assert DocRefs.sub_order_ref(nil) == nil
    end

    test "returns nil for unknown uuid" do
      assert DocRefs.sub_order_ref(Ecto.UUID.generate()) == nil
    end

    test "returns #parent_num-sub_num label via the registered sub_order source kind" do
      {parent, sub} = create_sub_order!()
      ref = DocRefs.sub_order_ref(sub.uuid)

      parent_num = parent.data["order_number"]
      sub_num = sub.data["sub_order_number"]

      assert ref != nil
      assert ref.label == "##{parent_num}-#{sub_num}"
      assert ref.kind == :sub_order
    end
  end

  # ---------------------------------------------------------------------------
  # sub_order_refs/1 (batch)
  # ---------------------------------------------------------------------------

  describe "sub_order_refs/1" do
    test "returns empty map for empty list" do
      assert DocRefs.sub_order_refs([]) == %{}
    end

    test "batch resolves multiple sub-orders" do
      {p1, sub1} = create_sub_order!()
      {p2, sub2} = create_sub_order!()

      refs = DocRefs.sub_order_refs([sub1.uuid, sub2.uuid])

      assert map_size(refs) == 2

      assert refs[sub1.uuid].label ==
               "##{p1.data["order_number"]}-#{sub1.data["sub_order_number"]}"

      assert refs[sub2.uuid].label ==
               "##{p2.data["order_number"]}-#{sub2.data["sub_order_number"]}"
    end
  end
end
