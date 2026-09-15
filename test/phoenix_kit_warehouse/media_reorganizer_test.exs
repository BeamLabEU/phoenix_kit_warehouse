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

    def parent(resource, _actor) do
      Process.put({:calls, resource}, (Process.get({:calls, resource}) || 0) + 1)
      {:ok, Process.get({:target, resource})}
    end
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
  # Hook batching — the host hook is record-independent (kind, actor_uuid),
  # so it must be resolved once per kind, not once per record.
  # ---------------------------------------------------------------------------

  test "storage_parent_folder hook is called once per kind, not once per record" do
    issue_a = create_goods_issue!()
    issue_b = create_goods_issue!()
    issue_c = create_goods_issue!()
    {:ok, target} = Storage.create_folder(%{name: "Goods issues"})

    for issue <- [issue_a, issue_b, issue_c] do
      {:ok, _} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
    end

    put_hook(:goods_issue, target.uuid)

    MediaReorganizer.plan(nil, [])

    assert Process.get({:calls, :goods_issue}) == 1
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
    put_hook(:transfer, nil)

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

    test "orphan folder under a resolved parent is found even when the kind has no live documents" do
      {:ok, target} = Storage.create_folder(%{name: "Goods receipts"})

      {:ok, folder} =
        Storage.create_folder(%{
          name: "goods-receipt-#{Ecto.UUID.generate()}",
          parent_uuid: target.uuid
        })

      put_hook(:goods_receipt, target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.reason =~ "missing"
      assert Process.get({:calls, :goods_receipt}) == 1
    end

    test "a numeric suffix outside the bigint range does not crash the plan" do
      {:ok, folder} = Storage.create_folder(%{name: "transfer-99999999999999999999999999"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end
  end

  # ---------------------------------------------------------------------------
  # Hook batching / gating — X12, X13
  # ---------------------------------------------------------------------------

  test "hook is not resolved at all for a kind with no live document and no residual folder" do
    issue = create_goods_issue!()
    {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
    {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
    put_hook(:goods_issue, target.uuid)

    MediaReorganizer.plan(nil, [])

    assert Process.get({:calls, :goods_issue}) == 1
    assert is_nil(Process.get({:calls, :transfer}))
  end

  # ---------------------------------------------------------------------------
  # No hook configured — D1: nothing is planned, not even a back-fill
  # ---------------------------------------------------------------------------

  test "no hook configured -> not even a pointer back-fill is planned" do
    issue = create_goods_issue!()
    {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :goods_issue))
  end

  # ---------------------------------------------------------------------------
  # Pointer wins over a root legacy-named folder
  # ---------------------------------------------------------------------------

  test "a live pointer wins over an unrelated root legacy folder" do
    issue = create_goods_issue!()
    {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
    {:ok, pointed} = Storage.create_folder(%{name: "Custom name"})
    {:ok, _root_lookalike} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
    {:ok, _} = GoodsIssues.set_storage_folder(issue, pointed.uuid)
    put_hook(:goods_issue, target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    goods_issue_actions = Enum.filter(actions, &(&1.kind == :goods_issue))

    assert [action] = goods_issue_actions
    assert action.folder.uuid == pointed.uuid
    assert action.parent_uuid == target.uuid
    refute Enum.any?(actions, &(&1.kind == :orphan))
  end

  # ---------------------------------------------------------------------------
  # X2 — a trashed folder must not hide a live folder with the same name
  # ---------------------------------------------------------------------------

  test "a trashed folder with the same legacy name does not hide the live one" do
    issue = create_goods_issue!()
    name = "goods-issue-#{issue.number}"
    {:ok, trashed} = Storage.create_folder(%{name: name})
    {:ok, _trashed} = Storage.trash_folder(trashed)
    {:ok, live} = Storage.create_folder(%{name: name})
    {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
    put_hook(:goods_issue, target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :goods_issue))

    refute is_nil(action)
    assert action.folder.uuid == live.uuid
  end

  # ---------------------------------------------------------------------------
  # X11 — legacy name live at both root and under the resolved parent
  # ---------------------------------------------------------------------------

  test "legacy name live at both root and under the resolved parent -> duplicate report, no move" do
    issue = create_goods_issue!()
    name = "goods-issue-#{issue.number}"
    {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
    {:ok, at_root} = Storage.create_folder(%{name: name})
    {:ok, under_parent} = Storage.create_folder(%{name: name, parent_uuid: target.uuid})
    put_hook(:goods_issue, target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    dup = Enum.find(actions, &(&1.kind == :duplicate))

    refute is_nil(dup)
    assert dup.op == :report
    assert dup.reason =~ at_root.uuid
    assert dup.reason =~ under_parent.uuid
    refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
  end

  # ---------------------------------------------------------------------------
  # X5 — two documents resolving to the very same live folder
  # ---------------------------------------------------------------------------

  test "two documents pointing at the same folder -> one duplicate report, no move" do
    issue_a = create_goods_issue!()
    issue_b = create_goods_issue!()
    {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
    {:ok, shared} = Storage.create_folder(%{name: "Shared", parent_uuid: target.uuid})
    {:ok, _} = GoodsIssues.set_storage_folder(issue_a, shared.uuid)
    {:ok, _} = GoodsIssues.set_storage_folder(issue_b, shared.uuid)
    put_hook(:goods_issue, target.uuid)

    actions = MediaReorganizer.plan(nil, [])
    dup = Enum.find(actions, &(&1.kind == :duplicate and &1.reason =~ shared.uuid))

    refute is_nil(dup)
    assert dup.op == :report
    refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
  end

  # ---------------------------------------------------------------------------
  # The Source never creates a folder
  # ---------------------------------------------------------------------------

  test "plan/2 never creates a folder as a side effect" do
    issue = create_goods_issue!()
    {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
    {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
    put_hook(:goods_issue, target.uuid)

    repo = PhoenixKit.RepoHelper.repo()
    before_count = repo.aggregate(PhoenixKit.Modules.Storage.Folder, :count)
    MediaReorganizer.plan(nil, [])
    after_count = repo.aggregate(PhoenixKit.Modules.Storage.Folder, :count)

    assert before_count == after_count
  end
end
