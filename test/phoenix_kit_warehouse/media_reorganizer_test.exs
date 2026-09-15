defmodule PhoenixKitWarehouse.MediaReorganizerTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.MediaReorganizer
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Transfers

  defmodule Hook do
    @moduledoc false
    def parent(resource, _actor), do: {:ok, Process.get({:target, resource})}
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :storage_parent_folder) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp user_uuid do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "reorg-test-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Reorg",
        "last_name" => "Test"
      })

    user.uuid
  end

  defp create_goods_issue! do
    {:ok, issue} = GoodsIssues.create_goods_issue(%{})
    issue
  end

  defp create_goods_receipt! do
    {:ok, receipt} = GoodsReceipts.create_goods_receipt(%{})
    receipt
  end

  defp create_inventory! do
    {:ok, doc} = Inventories.create_draft(%{})
    doc
  end

  defp create_supplier_order! do
    {:ok, supplier} =
      Catalogue.create_supplier(%{
        name: "Supplier #{System.unique_integer([:positive])}",
        status: "active"
      })

    {:ok, order} = SupplierOrders.create_supplier_order(%{supplier_uuid: supplier.uuid})
    order
  end

  defp create_internal_order! do
    {:ok, order} = InternalOrders.create_internal_order(%{})
    order
  end

  defp create_transfer! do
    {:ok, transfer} = Transfers.create_transfer(%{})
    transfer
  end

  defp put_hook(resource, target_uuid) do
    Process.put({:target, resource}, target_uuid)
    Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {Hook, :parent})
  end

  # Every resource kind's fixture, the prefix its folder name uses, its
  # `get_*!/1` reload, and its `set_storage_folder/2` setter (nil for
  # `InternalOrder`, which has no pointer column).
  defp resource_table do
    %{
      goods_issue:
        {&create_goods_issue!/0, "goods-issue", &GoodsIssues.get_goods_issue!/1,
         &GoodsIssues.set_storage_folder/2},
      goods_receipt:
        {&create_goods_receipt!/0, "goods-receipt", &GoodsReceipts.get_goods_receipt!/1,
         &GoodsReceipts.set_storage_folder/2},
      inventory:
        {&create_inventory!/0, "inventory", &Inventories.get_document!/1,
         &Inventories.set_storage_folder/2},
      supplier_order:
        {&create_supplier_order!/0, "supplier-order", &SupplierOrders.get_supplier_order!/1,
         &SupplierOrders.set_storage_folder/2},
      internal_order:
        {&create_internal_order!/0, "internal-order", &InternalOrders.get_internal_order!/1, nil},
      transfer:
        {&create_transfer!/0, "transfer", &Transfers.get_transfer!/1,
         &Transfers.set_storage_folder/2}
    }
  end

  # ---------------------------------------------------------------------------
  # No hook
  # ---------------------------------------------------------------------------

  test "no hook configured, legacy folder at root, pointer set -> nothing planned" do
    issue = create_goods_issue!()
    {:ok, folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
    {:ok, _} = GoodsIssues.set_storage_folder(issue, folder.uuid)

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.folder.uuid == folder.uuid))
  end

  # ---------------------------------------------------------------------------
  # Move via hook — every resource kind
  # ---------------------------------------------------------------------------

  # Compile-time list (kind, prefix) so `for` below can generate one `test`
  # per resource kind; the fixture functions themselves are resolved at
  # runtime inside each generated test via `resource_table/0`.
  @resource_kinds [
    {:goods_issue, "goods-issue"},
    {:goods_receipt, "goods-receipt"},
    {:inventory, "inventory"},
    {:supplier_order, "supplier-order"},
    {:internal_order, "internal-order"},
    {:transfer, "transfer"}
  ]

  describe "move via hook, every resource kind" do
    for {kind, prefix} <- @resource_kinds do
      test "#{kind}: legacy root folder + hook -> move action" do
        {create_fun, _prefix, _get_fun, _setter} = resource_table()[unquote(kind)]
        record = create_fun.()

        {:ok, target} = Storage.create_folder(%{name: "Documents #{unquote(kind)}"})
        {:ok, folder} = Storage.create_folder(%{name: "#{unquote(prefix)}-#{record.number}"})
        put_hook(unquote(kind), target.uuid)

        actions = MediaReorganizer.plan(nil, [])
        action = Enum.find(actions, &(&1.kind == unquote(kind) and &1.folder.uuid == folder.uuid))

        refute is_nil(action)
        assert action.source == "warehouse"
        assert action.op == :move
        assert action.parent_uuid == target.uuid
        assert action.name == "#{unquote(prefix)}-#{record.number}"
        assert action.on_conflict == :suffix
        assert action.counts == {0, 0}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Pointer back-fill
  # ---------------------------------------------------------------------------

  test "pointer missing (folder found by legacy name) -> after_move back-fills it" do
    receipt = create_goods_receipt!()
    {:ok, target} = Storage.create_folder(%{name: "Receipts"})
    {:ok, folder} = Storage.create_folder(%{name: "goods-receipt-#{receipt.number}"})
    put_hook(:goods_receipt, target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :goods_receipt))

    refute is_nil(action)
    assert action.folder.uuid == folder.uuid
    assert is_function(action.after_move, 0)

    assert :ok = action.after_move.()
    reloaded = GoodsReceipts.get_goods_receipt!(receipt.uuid)
    assert reloaded.storage_folder_uuid == folder.uuid
  end

  test "internal order has no pointer column -> after_move is always nil, even when moved" do
    order = create_internal_order!()
    {:ok, target} = Storage.create_folder(%{name: "Internal orders"})
    {:ok, _folder} = Storage.create_folder(%{name: "internal-order-#{order.number}"})
    put_hook(:internal_order, target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :internal_order))

    refute is_nil(action)
    assert action.op == :move
    assert is_nil(action.after_move)
  end

  # ---------------------------------------------------------------------------
  # Trashed pointer vs. live legacy folder
  # ---------------------------------------------------------------------------

  test "pointer points at a trashed folder while a live legacy folder exists at root -> the live one is used" do
    transfer = create_transfer!()

    {:ok, trashed} = Storage.create_folder(%{name: "old-pointer-target"})
    {:ok, trashed} = Storage.trash_folder(trashed)
    {:ok, live} = Storage.create_folder(%{name: "transfer-#{transfer.number}"})
    {:ok, _} = Transfers.set_storage_folder(transfer, trashed.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :transfer))

    refute is_nil(action)
    assert action.folder.uuid == live.uuid
  end

  # ---------------------------------------------------------------------------
  # In-place folder
  # ---------------------------------------------------------------------------

  test "folder already at the right parent/name but pointer missing -> move action with after_move" do
    order = create_supplier_order!()
    {:ok, target} = Storage.create_folder(%{name: "Supplier orders"})

    {:ok, folder} =
      Storage.create_folder(%{name: "supplier-order-#{order.number}", parent_uuid: target.uuid})

    put_hook(:supplier_order, target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :supplier_order))

    refute is_nil(action)
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == folder.name
    assert is_function(action.after_move, 0)
  end

  test "folder already at the right parent/name and pointer already correct -> nothing planned" do
    doc = create_inventory!()
    {:ok, target} = Storage.create_folder(%{name: "Inventory docs"})

    {:ok, folder} =
      Storage.create_folder(%{name: "inventory-#{doc.number}", parent_uuid: target.uuid})

    {:ok, _} = Inventories.set_storage_folder(doc, folder.uuid)
    put_hook(:inventory, target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :inventory and &1.folder.uuid == folder.uuid))
  end

  # ---------------------------------------------------------------------------
  # Counts
  # ---------------------------------------------------------------------------

  test "counts include a trashed file — the engine re-measures the same way at apply time" do
    user_uuid = user_uuid()
    issue = create_goods_issue!()
    {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
    {:ok, folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
    {:ok, _} = GoodsIssues.set_storage_folder(issue, folder.uuid)

    {:ok, _trashed_file} =
      Storage.create_file(%{
        original_file_name: "old.pdf",
        file_name: "old.pdf",
        mime_type: "application/pdf",
        file_type: "document",
        ext: "pdf",
        file_checksum: "checksum-trashed",
        user_file_checksum: "user-checksum-trashed",
        size: 10,
        status: "trashed",
        folder_uuid: folder.uuid,
        user_uuid: user_uuid
      })

    put_hook(:goods_issue, target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :goods_issue))

    assert action.counts == {1, 0}
  end

  # ---------------------------------------------------------------------------
  # Orphan folders
  # ---------------------------------------------------------------------------

  describe "orphan folders" do
    test "legacy folder with a uuid suffix and no matching record -> orphan report" do
      {:ok, folder} = Storage.create_folder(%{name: "goods-issue-#{Ecto.UUID.generate()}"})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.source == "warehouse"
      assert action.op == :report
      assert action.counts == {0, 0}
      assert action.reason =~ "missing"
    end

    test "legacy folder with a number suffix and no matching record -> orphan report" do
      {:ok, folder} = Storage.create_folder(%{name: "transfer-999999"})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.reason =~ "missing"
    end

    test "legacy folder of a soft-deleted document -> report names the record's status" do
      order = create_internal_order!()
      {:ok, folder} = Storage.create_folder(%{name: "internal-order-#{order.number}"})
      {:ok, _order} = InternalOrders.soft_delete_internal_order(order, nil)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ "draft"
    end

    test "legacy folder of a live document -> not reported as orphan" do
      transfer = create_transfer!()
      {:ok, folder} = Storage.create_folder(%{name: "transfer-#{transfer.number}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "a folder whose name does not match any legacy prefix is ignored" do
      {:ok, _folder} = Storage.create_folder(%{name: "unrelated-folder-name"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan))
    end
  end
end
