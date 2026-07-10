defmodule PhoenixKitWarehouse.SourceKindsIntegrationTest do
  @moduledoc """
  Proves InternalOrders/GoodsIssues/DocRefs call through SourceKinds
  end-to-end from the context layer — not just the registry-level dispatch
  Plan 2's own SourceKindsTest already covers.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.DocRefs
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.Test.FakeOrderSources

  @default_location "00000000-0000-0000-0000-000000000001"

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :source_kinds) end)
    :ok
  end

  defp create_internal_order!(attrs \\ %{}) do
    {:ok, order} =
      InternalOrders.create_internal_order(Map.merge(%{location_uuid: @default_location}, attrs))

    order
  end

  # ---------------------------------------------------------------------------
  # Zero source_kinds configured — everything degrades gracefully, no crash
  # ---------------------------------------------------------------------------

  describe "with zero source_kinds configured" do
    setup do
      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [])
      :ok
    end

    test "InternalOrders.list_import_candidates/1 returns [] without crashing" do
      assert InternalOrders.list_import_candidates() == []
      assert InternalOrders.list_import_candidates("anything") == []
    end

    test "InternalOrders.import_from_sources/3 no-ops for an unresolvable ref (no crash)" do
      order = create_internal_order!()
      ref = %{"type" => "sub_order", "uuid" => Ecto.UUID.generate()}

      assert {:ok, updated} =
               InternalOrders.import_from_sources(order, [ref], Ecto.UUID.generate())

      assert updated.lines == []
    end

    test "DocRefs.order_ref/1 and .sub_order_ref/1 return nil, not a crash" do
      uuid = Ecto.UUID.generate()
      assert DocRefs.order_ref(uuid) == nil
      assert DocRefs.sub_order_ref(uuid) == nil
    end

    test "DocRefs.refs_for/1 renders a plain-uuid placeholder for an order/sub_order ref instead of dropping it" do
      uuid = Ecto.UUID.generate()

      refs =
        DocRefs.refs_for([
          %{"type" => "order", "uuid" => uuid},
          %{"type" => "sub_order", "uuid" => uuid}
        ])

      assert [
               %{label: ^uuid, path: nil, uuid: ^uuid, kind: :order},
               %{label: ^uuid, path: nil, uuid: ^uuid, kind: :sub_order}
             ] = refs
    end
  end

  # ---------------------------------------------------------------------------
  # One fake kind configured — search/build_lines/resolve wire through
  # correctly end to end from the context layer
  # ---------------------------------------------------------------------------

  describe "with the sub_order kind registered" do
    setup do
      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
        FakeOrderSources.sub_order_kind()
      ])

      :ok
    end

    test "InternalOrders.list_import_candidates/1 surfaces the fake sub-order" do
      sub =
        FakeOrderSources.put_sub_order(%{
          uuid: Ecto.UUID.generate(),
          label: "fake-sub-42",
          lines: []
        })

      candidates = InternalOrders.list_import_candidates()

      assert [%{kind: "sub_order", label_prefix: "Sub-order", uuid: uuid, label: "fake-sub-42"}] =
               candidates

      assert uuid == sub.uuid
    end

    test "InternalOrders.import_from_sources/3 pulls lines through SourceKinds.build_lines/3" do
      sub =
        FakeOrderSources.put_sub_order(%{
          uuid: Ecto.UUID.generate(),
          label: "fake-sub-lines",
          lines: [%{"item_uuid" => Ecto.UUID.generate(), "required_quantity" => "4"}]
        })

      order = create_internal_order!()
      ref = %{"type" => "sub_order", "uuid" => sub.uuid}

      {:ok, updated} = InternalOrders.import_from_sources(order, [ref], Ecto.UUID.generate())

      assert [%{"required_quantity" => "4"}] = updated.lines
      assert %{"type" => "sub_order", "uuid" => sub_uuid} = hd(updated.source_refs)
      assert sub_uuid == sub.uuid
    end

    test "DocRefs.sub_order_ref/1 resolves through SourceKinds.resolve/2" do
      sub =
        FakeOrderSources.put_sub_order(%{
          uuid: Ecto.UUID.generate(),
          label: "fake-sub-ref",
          lines: []
        })

      assert %{label: "fake-sub-ref", kind: :sub_order} = DocRefs.sub_order_ref(sub.uuid)
    end

    test "DocRefs.refs_for/1 resolves a sub_order ref via the registered kind" do
      sub =
        FakeOrderSources.put_sub_order(%{
          uuid: Ecto.UUID.generate(),
          label: "fake-sub-list",
          lines: []
        })

      assert [%{label: "fake-sub-list", kind: :sub_order}] =
               DocRefs.refs_for([%{"type" => "sub_order", "uuid" => sub.uuid}])
    end

    test "GoodsIssues.add_source_ref/3 rejects an unregistered kind but accepts a registered one" do
      io = create_internal_order!()

      {:ok, issue} =
        GoodsIssues.create_goods_issue(%{
          internal_order_uuid: io.uuid,
          location_uuid: @default_location
        })

      assert {:error, :invalid_ref_type} =
               GoodsIssues.add_source_ref(issue, "order", Ecto.UUID.generate())

      assert {:ok, updated} = GoodsIssues.add_source_ref(issue, "sub_order", Ecto.UUID.generate())
      assert length(updated.source_refs) == 1
    end
  end
end
