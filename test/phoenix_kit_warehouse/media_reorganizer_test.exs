defmodule PhoenixKitWarehouse.MediaReorganizerTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  import ExUnit.CaptureLog

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

  defmodule RaisingHook do
    @moduledoc false
    def parent(:goods_issue, _actor), do: raise("boom")
    def parent(resource, _actor), do: {:ok, Process.get({:target, resource})}
  end

  defmodule ErrorHook do
    @moduledoc false
    def parent(:goods_issue, _actor), do: {:error, :timeout}
    def parent(_resource, _actor), do: nil
  end

  defmodule GarbageUuidHook do
    @moduledoc false
    def parent(_resource, _actor), do: {:ok, "not-a-uuid"}
  end

  defmodule UppercaseUuidHook do
    @moduledoc false
    def parent(resource, _actor), do: {:ok, Process.get({:target, resource}) |> String.upcase()}
  end

  defmodule EmptyStringUuidHook do
    @moduledoc false
    def parent(_resource, _actor), do: {:ok, ""}
  end

  # A module that exists but does not export the configured function name —
  # T3: distinct from "not configured at all".
  defmodule NotCallableHook do
    @moduledoc false
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

        # D3: internal_order has no pointer column, so a renamed folder
        # would be orphaned — it reports on collision instead of suffixing.
        expected_conflict = if unquote(kind) == :internal_order, do: :report, else: :suffix
        assert action.on_conflict == expected_conflict
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

    # F4 (strict, head ruling R4-1): a candidate is a live document with a
    # folder — a residual folder with zero live documents behind it never
    # makes its kind a candidate, so the hook is never called for it and an
    # orphan sitting under the parent that call WOULD have resolved is
    # invisible to this scan (documented in the moduledoc's F4 bullet).
    test "orphan folder under an unresolved parent is not found when its kind has no live documents (F4)" do
      {:ok, target} = Storage.create_folder(%{name: "Goods receipts"})

      {:ok, folder} =
        Storage.create_folder(%{
          name: "goods-receipt-#{Ecto.UUID.generate()}",
          parent_uuid: target.uuid
        })

      put_hook(:goods_receipt, target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
      assert is_nil(Process.get({:calls, :goods_receipt}))
    end

    test "a numeric suffix outside the bigint range does not crash the plan" do
      {:ok, folder} = Storage.create_folder(%{name: "transfer-99999999999999999999999999"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end
  end

  # ---------------------------------------------------------------------------
  # Orphan scope includes parents a non-move candidate's hook call resolved
  # (U4) — `ok_parents` is populated purely by a successful hook call for
  # the kind, independent of what any individual candidate's outcome ends
  # up being (`:duplicate`, `:relocated`, `:hook_nil` all still count).
  # ---------------------------------------------------------------------------

  test "orphan under a parent only a :duplicate (non-move) candidate resolved is still reported (U4)" do
    receipt = create_goods_receipt!()
    legacy_name = "goods-receipt-#{receipt.number}"
    {:ok, target} = Storage.create_folder(%{name: "Goods receipts"})

    # Ambiguous: the same legacy name live at both root and under the
    # resolved parent -> `:duplicate` report, no move planned for it.
    {:ok, _at_root} = Storage.create_folder(%{name: legacy_name})
    {:ok, _under_target} = Storage.create_folder(%{name: legacy_name, parent_uuid: target.uuid})

    # A genuinely orphaned folder living under that very same resolved
    # parent, for a document that no longer exists.
    {:ok, orphan_folder} =
      Storage.create_folder(%{
        name: "goods-receipt-#{Ecto.UUID.generate()}",
        parent_uuid: target.uuid
      })

    put_hook(:goods_receipt, target.uuid)

    actions = MediaReorganizer.plan(nil, [])

    assert Enum.any?(actions, &(&1.kind == :duplicate))
    refute Enum.any?(actions, &(&1.kind == :goods_receipt and &1.op == :move))

    orphan = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == orphan_folder.uuid))
    refute is_nil(orphan)
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

  # U9: a THIRD (or further) live copy of the exact same legacy name beyond
  # the ambiguous pair (root + resolved parent) must still be surfaced —
  # not silently dropped just because the pair itself is unresolvable.
  test "a third live copy of the same legacy name beyond the ambiguous pair is still reported :relocated (U9)" do
    issue = create_goods_issue!()
    name = "goods-issue-#{issue.number}"
    {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
    {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

    {:ok, _at_root} = Storage.create_folder(%{name: name})
    {:ok, _under_parent} = Storage.create_folder(%{name: name, parent_uuid: target.uuid})
    {:ok, third_copy} = Storage.create_folder(%{name: name, parent_uuid: elsewhere.uuid})

    put_hook(:goods_issue, target.uuid)

    actions = MediaReorganizer.plan(nil, [])

    assert Enum.any?(actions, &(&1.kind == :duplicate))
    refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))

    relocated =
      Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == third_copy.uuid))

    refute is_nil(relocated)
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

  # ---------------------------------------------------------------------------
  # Hook failure (R2) — a raising/erroring hook is never treated as root
  # ---------------------------------------------------------------------------

  describe "hook failure (R2)" do
    test "hook raises for a kind -> that kind's candidates skipped, one hook_error report, never moved to root" do
      issue = create_goods_issue!()
      {:ok, container} = Storage.create_folder(%{name: "Some container"})

      {:ok, pointer_folder} =
        Storage.create_folder(%{
          name: "goods-issue-#{issue.number}",
          parent_uuid: container.uuid
        })

      {:ok, _} = GoodsIssues.set_storage_folder(issue, pointer_folder.uuid)

      Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {RaisingHook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.op == :report
      assert error.reason =~ "1 document"
    end

    test "hook returns {:error, _} for a kind -> same as raising, never treated as root" do
      issue = create_goods_issue!()
      {:ok, folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
      {:ok, _} = GoodsIssues.set_storage_folder(issue, folder.uuid)

      Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {ErrorHook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end

    test "hook failure for one kind does not block another kind's plan" do
      issue = create_goods_issue!()
      transfer = create_transfer!()

      {:ok, _} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
      {:ok, target} = Storage.create_folder(%{name: "Transfers"})
      {:ok, _} = Storage.create_folder(%{name: "transfer-#{transfer.number}"})

      # RaisingHook only raises for :goods_issue; every other resource still
      # resolves normally — a real hook failure for one kind must not
      # affect another.
      Process.put({:target, :transfer}, target.uuid)
      Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {RaisingHook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue))
      transfer_action = Enum.find(actions, &(&1.kind == :transfer))
      refute is_nil(transfer_action)
      assert transfer_action.op == :move
      assert transfer_action.parent_uuid == target.uuid
    end
  end

  # ---------------------------------------------------------------------------
  # Numeric legacy suffix strictness (F2)
  # ---------------------------------------------------------------------------

  describe "numeric suffix strictness (F2)" do
    test "a leading-zero numeric suffix is not treated as a document id" do
      {:ok, _folder} = Storage.create_folder(%{name: "transfer-00690"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan))
    end

    test "a plus-signed numeric suffix is not treated as a document id" do
      {:ok, _folder} = Storage.create_folder(%{name: "transfer-+690"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan))
    end

    test "a negative numeric suffix is not treated as a document id" do
      {:ok, _folder} = Storage.create_folder(%{name: "transfer--1"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan))
    end
  end

  # ---------------------------------------------------------------------------
  # Orphans exclude claimed folders, hook-independent (R1/R4)
  # ---------------------------------------------------------------------------

  describe "orphans exclude claimed folders, hook-independent (R1/R4)" do
    test "a pointer's folder is never reported as an orphan even when its name coincidentally matches another (missing) document's legacy pattern, with no hook configured" do
      issue = create_goods_issue!()
      other_number = issue.number + 1000

      {:ok, folder} = Storage.create_folder(%{name: "goods-issue-#{other_number}"})
      {:ok, _} = GoodsIssues.set_storage_folder(issue, folder.uuid)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy folder relocated elsewhere (F4a)
  # ---------------------------------------------------------------------------

  describe "legacy folder relocated elsewhere (F4a)" do
    test "legacy folder live under a parent that isn't root or the resolved parent -> reported :relocated, not adopted" do
      issue = create_goods_issue!()
      {:ok, elsewhere} = Storage.create_folder(%{name: "Some other container"})

      {:ok, legacy} =
        Storage.create_folder(%{
          name: "goods-issue-#{issue.number}",
          parent_uuid: elsewhere.uuid
        })

      {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
      put_hook(:goods_issue, target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
      relocated = Enum.find(actions, &(&1.kind == :relocated))
      refute is_nil(relocated)
      assert relocated.op == :report
      assert relocated.folder.uuid == legacy.uuid
    end
  end

  # ---------------------------------------------------------------------------
  # Converging targets (R7/E3)
  # ---------------------------------------------------------------------------

  describe "converging targets (R7/E3)" do
    test "two documents whose pointer folders were both renamed to the same name, neither already at the target -> duplicate, no moves" do
      issue_a = create_goods_issue!()
      issue_b = create_goods_issue!()

      {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Elsewhere"})
      {:ok, folder_a} = Storage.create_folder(%{name: "Renamed", parent_uuid: elsewhere.uuid})
      {:ok, folder_b} = Storage.create_folder(%{name: "Renamed"})

      {:ok, _} = GoodsIssues.set_storage_folder(issue_a, folder_a.uuid)
      {:ok, _} = GoodsIssues.set_storage_folder(issue_b, folder_b.uuid)

      put_hook(:goods_issue, target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.reason =~ "same destination"))
      refute is_nil(dup)
    end

    # U2: a genuine no-op (folder_a already sitting at the target, nothing
    # to move) never counts as a "converging" competitor — only real movers
    # can converge with each other. issue_b, the sole real mover here,
    # still gets its own `:move` (an `on_conflict: :suffix` action); the
    # physical collision with folder_a is the engine's problem at apply
    # time, not this plan's.
    test "one side already at the target and the other a real mover -> the real mover still gets a move, no duplicate" do
      issue_a = create_goods_issue!()
      issue_b = create_goods_issue!()

      {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
      {:ok, folder_a} = Storage.create_folder(%{name: "Renamed", parent_uuid: target.uuid})
      {:ok, folder_b} = Storage.create_folder(%{name: "Renamed"})

      {:ok, _} = GoodsIssues.set_storage_folder(issue_a, folder_a.uuid)
      {:ok, _} = GoodsIssues.set_storage_folder(issue_b, folder_b.uuid)

      put_hook(:goods_issue, target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :duplicate and &1.reason =~ "same destination"))

      move = Enum.find(actions, &(&1.kind == :goods_issue and &1.op == :move))
      refute is_nil(move)
      assert move.folder.uuid == folder_b.uuid
      assert move.parent_uuid == target.uuid
      assert move.on_conflict == :suffix
    end
  end

  # ---------------------------------------------------------------------------
  # Pointer-found folder name (D6/E2)
  # ---------------------------------------------------------------------------

  describe "pointer-found folder name (D6/E2)" do
    test "pointer folder still has the exact legacy name -> desired name applied" do
      issue = create_goods_issue!()
      {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
      {:ok, folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
      {:ok, _} = GoodsIssues.set_storage_folder(issue, folder.uuid)
      put_hook(:goods_issue, target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :goods_issue))

      refute is_nil(action)
      assert action.name == folder.name
    end

    test "pointer folder was renamed by the owner -> kept as-is, never overwritten" do
      issue = create_goods_issue!()
      {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
      {:ok, folder} = Storage.create_folder(%{name: "My Custom Name"})
      {:ok, _} = GoodsIssues.set_storage_folder(issue, folder.uuid)
      put_hook(:goods_issue, target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :goods_issue))

      refute is_nil(action)
      assert is_nil(action.name)
    end
  end

  # ---------------------------------------------------------------------------
  # after_move re-checks the document under lock at apply time (F10)
  # ---------------------------------------------------------------------------

  describe "after_move re-checks the document under lock (F10)" do
    test "document soft-deleted between plan and apply -> after_move returns {:error, :record_deleted}" do
      receipt = create_goods_receipt!()
      {:ok, target} = Storage.create_folder(%{name: "Receipts"})
      {:ok, _folder} = Storage.create_folder(%{name: "goods-receipt-#{receipt.number}"})
      put_hook(:goods_receipt, target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :goods_receipt))
      refute is_nil(action)

      {:ok, _} = GoodsReceipts.soft_delete(receipt, nil)

      assert {:error, :record_deleted} = action.after_move.()
    end

    test "pointer changed between plan and apply -> after_move returns {:error, :pointer_changed}, pointer kept" do
      receipt = create_goods_receipt!()
      {:ok, target} = Storage.create_folder(%{name: "Receipts"})
      {:ok, _folder} = Storage.create_folder(%{name: "goods-receipt-#{receipt.number}"})
      put_hook(:goods_receipt, target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :goods_receipt))
      refute is_nil(action)

      # e.g. `StorageFolders.ensure_for_goods_receipt/2` cached a fresh
      # folder in between — the back-fill must not strand it.
      {:ok, fresh} = Storage.create_folder(%{name: "Fresh", parent_uuid: target.uuid})
      {:ok, _} = GoodsReceipts.set_storage_folder(receipt, fresh.uuid)

      assert {:error, :pointer_changed} = action.after_move.()
      assert GoodsReceipts.get_goods_receipt!(receipt.uuid).storage_folder_uuid == fresh.uuid
    end

    test "pointer already set to the moved folder between plan and apply -> after_move is :ok" do
      receipt = create_goods_receipt!()
      {:ok, target} = Storage.create_folder(%{name: "Receipts"})
      {:ok, folder} = Storage.create_folder(%{name: "goods-receipt-#{receipt.number}"})
      put_hook(:goods_receipt, target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :goods_receipt))
      refute is_nil(action)

      {:ok, _} = GoodsReceipts.set_storage_folder(receipt, folder.uuid)

      assert :ok = action.after_move.()
      assert GoodsReceipts.get_goods_receipt!(receipt.uuid).storage_folder_uuid == folder.uuid
    end

    test "pointer unchanged since plan -> after_move writes it" do
      receipt = create_goods_receipt!()
      {:ok, target} = Storage.create_folder(%{name: "Receipts"})
      {:ok, folder} = Storage.create_folder(%{name: "goods-receipt-#{receipt.number}"})
      put_hook(:goods_receipt, target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :goods_receipt))
      refute is_nil(action)

      assert :ok = action.after_move.()
      assert GoodsReceipts.get_goods_receipt!(receipt.uuid).storage_folder_uuid == folder.uuid
    end
  end

  # ---------------------------------------------------------------------------
  # on_conflict per kind (D3/F4b)
  # ---------------------------------------------------------------------------

  describe "on_conflict per kind (D3/F4b)" do
    test "internal_order (no pointer column) reports on collision instead of suffixing" do
      order = create_internal_order!()
      {:ok, target} = Storage.create_folder(%{name: "Internal orders"})
      {:ok, _folder} = Storage.create_folder(%{name: "internal-order-#{order.number}"})
      put_hook(:internal_order, target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :internal_order))

      refute is_nil(action)
      assert action.on_conflict == :report
    end

    test "a pointer-writing kind suffixes on collision" do
      issue = create_goods_issue!()
      {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
      put_hook(:goods_issue, target.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :goods_issue))

      refute is_nil(action)
      assert action.on_conflict == :suffix
    end
  end

  # ---------------------------------------------------------------------------
  # Stray legacy twin next to the resolved folder
  # ---------------------------------------------------------------------------

  describe "stray legacy twin next to the resolved folder" do
    test "pointer already correct AND a live legacy-named twin exists elsewhere -> the twin is reported :relocated" do
      issue = create_goods_issue!()
      {:ok, real_folder} = Storage.create_folder(%{name: "Somewhere real"})
      {:ok, twin} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
      {:ok, _} = GoodsIssues.set_storage_folder(issue, real_folder.uuid)

      actions = MediaReorganizer.plan(nil, [])

      # The document's actual (pointer) folder is untouched...
      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
      # ...but the stray legacy-named twin is neither silently dropped nor
      # mistaken for an orphan (the document is alive).
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == twin.uuid))
      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == twin.uuid))
      refute is_nil(relocated)
      # T5: the twin is at root — the reason must name its actual place.
      assert relocated.reason =~ "storage root"
    end

    test "host-resolved current folder at root AND a live legacy twin under another parent -> the twin is reported :relocated" do
      issue = create_goods_issue!()
      {:ok, elsewhere} = Storage.create_folder(%{name: "Some other container"})
      {:ok, root_folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      {:ok, twin} =
        Storage.create_folder(%{
          name: "goods-issue-#{issue.number}",
          parent_uuid: elsewhere.uuid
        })

      # Hook configured, resolves to root (nil) — the current folder is
      # found by name at root, same as the record's own deterministic
      # name, so only a pointer back-fill is planned for it.
      Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      action = Enum.find(actions, &(&1.kind == :goods_issue))
      refute is_nil(action)
      assert action.folder.uuid == root_folder.uuid
      assert is_function(action.after_move, 0)

      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == twin.uuid))
      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == twin.uuid))
      refute is_nil(relocated)
      # T5: the twin is under a real parent — the reason must say so, and
      # name that parent (Source contract).
      assert relocated.reason =~ "different parent"
      assert relocated.reason =~ ~s("Some other container")
      assert relocated.reason =~ elsewhere.uuid
    end

    test "stray twin already under the resolved target parent -> reason names the collision, not a blanket 'different parent'" do
      issue = create_goods_issue!()
      {:ok, target} = Storage.create_folder(%{name: "Goods issues"})

      {:ok, real_folder} =
        Storage.create_folder(%{name: "Somewhere real", parent_uuid: target.uuid})

      {:ok, twin} =
        Storage.create_folder(%{
          name: "goods-issue-#{issue.number}",
          parent_uuid: target.uuid
        })

      {:ok, _} = GoodsIssues.set_storage_folder(issue, real_folder.uuid)
      put_hook(:goods_issue, target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == twin.uuid))
      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == twin.uuid))
      refute is_nil(relocated)
      assert relocated.reason =~ "target parent"
      assert relocated.reason =~ "will collide"
      refute relocated.reason =~ "different parent"
    end

    test "two simultaneous stray twins for the same document (root and under the target parent) -> both reported :relocated with distinct reasons" do
      issue = create_goods_issue!()
      {:ok, target} = Storage.create_folder(%{name: "Goods issues"})

      {:ok, real_folder} =
        Storage.create_folder(%{name: "Somewhere real", parent_uuid: target.uuid})

      {:ok, root_twin} =
        Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      {:ok, target_twin} =
        Storage.create_folder(%{
          name: "goods-issue-#{issue.number}",
          parent_uuid: target.uuid
        })

      {:ok, _} = GoodsIssues.set_storage_folder(issue, real_folder.uuid)
      put_hook(:goods_issue, target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      # The document's actual (pointer) folder is untouched...
      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))

      relocated_uuids =
        actions
        |> Enum.filter(&(&1.kind == :relocated))
        |> Enum.map(& &1.folder.uuid)

      assert root_twin.uuid in relocated_uuids
      assert target_twin.uuid in relocated_uuids

      root_relocated =
        Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == root_twin.uuid))

      target_relocated =
        Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == target_twin.uuid))

      assert root_relocated.reason =~ "storage root"
      assert target_relocated.reason =~ "will collide"
    end
  end

  # ---------------------------------------------------------------------------
  # E1: reports still appear without a configured hook
  # ---------------------------------------------------------------------------

  describe "E1: reports still appear without a configured hook" do
    test "no hook configured, legacy folder live under some parent (not root) -> reported :relocated" do
      issue = create_goods_issue!()
      {:ok, elsewhere} = Storage.create_folder(%{name: "Some other container"})

      {:ok, legacy} =
        Storage.create_folder(%{
          name: "goods-issue-#{issue.number}",
          parent_uuid: elsewhere.uuid
        })

      actions = MediaReorganizer.plan(nil, [])

      # No hook -> no move and no back-fill are ever planned for it...
      refute Enum.any?(actions, &(&1.kind == :goods_issue))
      # ...but the relocated report itself is not suppressed.
      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == legacy.uuid))
      refute is_nil(relocated)
    end

    test "no hook configured, two documents whose pointers name the same folder -> reported :duplicate" do
      issue1 = create_goods_issue!()
      issue2 = create_goods_issue!()
      {:ok, shared} = Storage.create_folder(%{name: "shared-folder"})
      {:ok, _} = GoodsIssues.set_storage_folder(issue1, shared.uuid)
      {:ok, _} = GoodsIssues.set_storage_folder(issue2, shared.uuid)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == shared.name))
      refute is_nil(dup)
    end

    test "no hook configured, orphan folders are still reported" do
      {:ok, _folder} =
        Storage.create_folder(%{name: "goods-issue-#{System.unique_integer([:positive])}"})

      actions = MediaReorganizer.plan(nil, [])

      assert Enum.any?(actions, &(&1.kind == :orphan))
    end
  end

  # ---------------------------------------------------------------------------
  # Hook answer is cast as a UUID (T1)
  # ---------------------------------------------------------------------------

  describe "hook answer is cast as a UUID (T1)" do
    test "hook returns {:ok, garbage} -> hook_error, never planned as a move into that literal value" do
      issue = create_goods_issue!()
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      Application.put_env(
        :phoenix_kit_warehouse,
        :storage_parent_folder,
        {GarbageUuidHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.op == :report
    end

    test "hook returns {:ok, \"\"} -> hook_error, not a CastError" do
      issue = create_goods_issue!()
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      Application.put_env(
        :phoenix_kit_warehouse,
        :storage_parent_folder,
        {EmptyStringUuidHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end

    test "hook returns an upper-case (but well-formed) uuid -> accepted and downcased, no hook_error" do
      issue = create_goods_issue!()
      {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
      Process.put({:target, :goods_issue}, target.uuid)

      Application.put_env(
        :phoenix_kit_warehouse,
        :storage_parent_folder,
        {UppercaseUuidHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :goods_issue))

      refute is_nil(action)
      assert action.op == :move
      assert action.parent_uuid == target.uuid
      refute Enum.any?(actions, &(&1.kind == :hook_error))
    end
  end

  # ---------------------------------------------------------------------------
  # Bad hook returns are logged, not only counted (U6)
  # ---------------------------------------------------------------------------

  describe "bad hook returns are logged with {mod, fun} and the kind (U6)" do
    test "a garbage UUID answer is logged, not just counted" do
      issue = create_goods_issue!()
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      Application.put_env(
        :phoenix_kit_warehouse,
        :storage_parent_folder,
        {GarbageUuidHook, :parent}
      )

      log = capture_log(fn -> MediaReorganizer.plan(nil, []) end)

      assert log =~ "GarbageUuidHook"
      assert log =~ ":parent"
      assert log =~ "goods_issue"
      assert log =~ "not-a-uuid"
    end

    test "an unexpected {:error, _} answer is logged, not just counted" do
      issue = create_goods_issue!()
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {ErrorHook, :parent})

      log = capture_log(fn -> MediaReorganizer.plan(nil, []) end)

      assert log =~ "ErrorHook"
      assert log =~ "goods_issue"
      assert log =~ "timeout"
    end
  end

  # ---------------------------------------------------------------------------
  # hook_error / hook_nil reports list record labels, not just a count (U8)
  # ---------------------------------------------------------------------------

  describe "hook_error and hook_nil reports list record labels (U8)" do
    test "hook_error names every failed document's legacy folder name" do
      issue = create_goods_issue!()
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {ErrorHook, :parent})

      actions = MediaReorganizer.plan(nil, [])
      error = Enum.find(actions, &(&1.kind == :hook_error))

      refute is_nil(error)
      assert error.reason =~ "goods-issue-#{issue.number}"
    end

    test "hook_nil names the document whose folder was left in place" do
      transfer = create_transfer!()
      {:ok, container} = Storage.create_folder(%{name: "Some container"})
      {:ok, folder} = Storage.create_folder(%{name: "Kept name", parent_uuid: container.uuid})
      {:ok, _} = Transfers.set_storage_folder(transfer, folder.uuid)

      put_hook(:transfer, nil)

      actions = MediaReorganizer.plan(nil, [])
      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))

      refute is_nil(hook_nil)
      assert hook_nil.reason =~ "transfer-#{transfer.number}"
    end

    test "more than 10 failed documents -> only the first 10 labels are listed, then a count of the rest" do
      Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {ErrorHook, :parent})

      issues =
        for _ <- 1..12 do
          issue = create_goods_issue!()
          {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
          issue
        end

      actions = MediaReorganizer.plan(nil, [])
      error = Enum.find(actions, &(&1.kind == :hook_error))

      refute is_nil(error)
      assert error.reason =~ "12 document(s)"
      assert error.reason =~ "… and 2 more"

      # Order among same-batch, same-timestamp records is not the point
      # here (T6 covers ordering elsewhere) — only that exactly 10 of the
      # 12 real labels are listed, each a real one, none repeated.
      all_labels = Enum.map(issues, &"goods-issue-#{&1.number}")
      [_, listed_part] = Regex.run(~r/nil \((.+), … and 2 more\)/, error.reason)
      listed = String.split(listed_part, ", ")

      assert length(listed) == 10
      assert Enum.uniq(listed) == listed
      assert Enum.all?(listed, &(&1 in all_labels))
    end
  end

  # ---------------------------------------------------------------------------
  # Explicit nil never moves a pointer-found folder out of its parent (F1/T2)
  # ---------------------------------------------------------------------------

  describe "explicit nil never moves a pointer-found folder to root (F1/T2)" do
    test "pointer folder already lives under a real parent, hook explicitly answers nil -> not moved to root, hook_nil reported" do
      issue = create_goods_issue!()
      {:ok, container} = Storage.create_folder(%{name: "Some container"})
      {:ok, folder} = Storage.create_folder(%{name: "Kept name", parent_uuid: container.uuid})
      {:ok, _} = GoodsIssues.set_storage_folder(issue, folder.uuid)

      put_hook(:goods_issue, nil)

      actions = MediaReorganizer.plan(nil, [])

      # Never moved out of `container`, and in particular never to root.
      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))

      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.op == :report
    end

    test "folder already at root, hook explicitly answers nil -> not a hook_nil case, no report" do
      issue = create_goods_issue!()
      {:ok, folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})
      {:ok, _} = GoodsIssues.set_storage_folder(issue, folder.uuid)

      put_hook(:goods_issue, nil)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :hook_nil))
    end
  end

  # ---------------------------------------------------------------------------
  # F1 also applies to the name-track, for pointer-writing kinds only (U1)
  # ---------------------------------------------------------------------------

  describe "F1 on the name-track, pointer-writing kinds (U1)" do
    test "no pointer, legacy folder under a real parent, hook answers nil -> adopted, back-filled, hook_nil, never :relocated" do
      transfer = create_transfer!()
      {:ok, container} = Storage.create_folder(%{name: "Some container"})

      {:ok, folder} =
        Storage.create_folder(%{
          name: "transfer-#{transfer.number}",
          parent_uuid: container.uuid
        })

      put_hook(:transfer, nil)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :relocated and &1.folder.uuid == folder.uuid))

      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.reason =~ folder.name

      move = Enum.find(actions, &(&1.kind == :transfer and &1.op == :move))
      refute is_nil(move)
      assert move.folder.uuid == folder.uuid
      assert move.parent_uuid == container.uuid
      assert move.name == nil
      refute is_nil(move.after_move)
    end

    test "no pointer set, legacy-named folder already at root, hook answers nil -> resolved normally, no hook_nil" do
      transfer = create_transfer!()
      {:ok, folder} = Storage.create_folder(%{name: "transfer-#{transfer.number}"})

      put_hook(:transfer, nil)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :hook_nil))
      refute Enum.any?(actions, &(&1.kind == :relocated and &1.folder.uuid == folder.uuid))
    end

    test "pointer-less internal_order keeps reporting :relocated when the hook answers nil (F1 does not extend to it)" do
      order = create_internal_order!()
      {:ok, container} = Storage.create_folder(%{name: "Some container"})

      {:ok, folder} =
        Storage.create_folder(%{
          name: "internal-order-#{order.number}",
          parent_uuid: container.uuid
        })

      put_hook(:internal_order, nil)

      actions = MediaReorganizer.plan(nil, [])

      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == folder.uuid))
      refute is_nil(relocated)
      refute Enum.any?(actions, &(&1.kind == :hook_nil))
    end

    test "no pointer, two legacy-named copies under two different real parents, hook answers nil -> neither adopted, both :relocated" do
      transfer = create_transfer!()
      {:ok, container1} = Storage.create_folder(%{name: "Container 1"})
      {:ok, container2} = Storage.create_folder(%{name: "Container 2"})

      {:ok, folder1} =
        Storage.create_folder(%{
          name: "transfer-#{transfer.number}",
          parent_uuid: container1.uuid
        })

      {:ok, folder2} =
        Storage.create_folder(%{
          name: "transfer-#{transfer.number}",
          parent_uuid: container2.uuid
        })

      put_hook(:transfer, nil)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :hook_nil))
      refute Enum.any?(actions, &(&1.kind == :transfer and &1.op == :move))

      relocated_uuids =
        actions
        |> Enum.filter(&(&1.kind == :relocated))
        |> Enum.map(& &1.folder.uuid)

      assert folder1.uuid in relocated_uuids
      assert folder2.uuid in relocated_uuids
    end
  end

  # ---------------------------------------------------------------------------
  # Configured hook is not callable (T3)
  # ---------------------------------------------------------------------------

  describe "configured hook is not callable (T3)" do
    test "hook module exists but the function is not exported -> hook_error \"not callable\", never silently no-hook" do
      issue = create_goods_issue!()
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      Application.put_env(
        :phoenix_kit_warehouse,
        :storage_parent_folder,
        {NotCallableHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
      error = Enum.find(actions, &(&1.kind == :hook_error and &1.reason =~ "not callable"))
      refute is_nil(error)
    end

    test "hook module does not exist at all -> hook_error \"not callable\"" do
      issue = create_goods_issue!()
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      Application.put_env(
        :phoenix_kit_warehouse,
        :storage_parent_folder,
        {PhoenixKitWarehouse.MediaReorganizerTest.NoSuchModuleAtAll, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      error = Enum.find(actions, &(&1.kind == :hook_error and &1.reason =~ "not callable"))
      refute is_nil(error)
    end
  end

  # ---------------------------------------------------------------------------
  # Configured hook is garbage (not a {mod, fun} tuple at all) — U7/V3
  # ---------------------------------------------------------------------------

  describe "configured hook is not a {mod, fun} tuple at all (U7/V3)" do
    test "a bare string config -> hook_error, never silently treated as no hook configured" do
      issue = create_goods_issue!()
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, "garbage")

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ inspect("garbage")
    end

    test "a 1-tuple config -> hook_error, never silently treated as no hook configured" do
      issue = create_goods_issue!()
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {SomeModule})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end

    test "a map config -> hook_error, never silently treated as no hook configured" do
      issue = create_goods_issue!()
      {:ok, _folder} = Storage.create_folder(%{name: "goods-issue-#{issue.number}"})

      Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, %{mod: SomeModule})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end
  end

  # ---------------------------------------------------------------------------
  # hook_error is reported even when only a kind's orphan scan is affected (T4)
  # ---------------------------------------------------------------------------

  # F4 (strict): a kind with a residual folder but zero live documents is
  # never a candidate, so a failing hook is never even called for it — no
  # `:hook_error`, the same as a healthy hook never being called for it
  # (the orphan-scan-only failure case this used to cover no longer exists,
  # see the moduledoc's F4 bullet).
  describe "hook_error is never raised for a residual-only kind (F4)" do
    test "a hook that would fail is never called for a kind with a residual folder but zero live documents" do
      # F4/R8: root scope needs no hook — a residual folder there is still
      # found (this is not the X13 behaviour being removed). A residual
      # folder under some OTHER real parent is not found: without a live
      # document of this kind, the hook (which would have failed) is never
      # even called, so no parent for this kind is ever resolved.
      {:ok, root_residual} = Storage.create_folder(%{name: "goods-issue-#{Ecto.UUID.generate()}"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Elsewhere"})

      {:ok, parented_residual} =
        Storage.create_folder(%{
          name: "goods-issue-#{Ecto.UUID.generate()}",
          parent_uuid: elsewhere.uuid
        })

      Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {RaisingHook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :hook_error))
      assert Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == root_residual.uuid))

      refute Enum.any?(
               actions,
               &(&1.kind == :orphan and &1.folder.uuid == parented_residual.uuid)
             )
    end
  end

  # ---------------------------------------------------------------------------
  # No false converging-target duplicate without a working hook (N3/F6)
  # ---------------------------------------------------------------------------

  describe "no false converging duplicate without a hook (N3/F6)" do
    test "no hook configured, two documents' pointer folders happen to share a name under different real parents -> no duplicate report" do
      issue_a = create_goods_issue!()
      issue_b = create_goods_issue!()
      {:ok, parent_a} = Storage.create_folder(%{name: "Parent A"})
      {:ok, parent_b} = Storage.create_folder(%{name: "Parent B"})
      {:ok, folder_a} = Storage.create_folder(%{name: "Shared name", parent_uuid: parent_a.uuid})
      {:ok, folder_b} = Storage.create_folder(%{name: "Shared name", parent_uuid: parent_b.uuid})
      {:ok, _} = GoodsIssues.set_storage_folder(issue_a, folder_a.uuid)
      {:ok, _} = GoodsIssues.set_storage_folder(issue_b, folder_b.uuid)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :duplicate and &1.reason =~ "same destination"))
    end

    test "hook explicitly answers nil for both documents -> no duplicate report, no moves" do
      issue_a = create_goods_issue!()
      issue_b = create_goods_issue!()
      {:ok, parent_a} = Storage.create_folder(%{name: "Parent A"})
      {:ok, parent_b} = Storage.create_folder(%{name: "Parent B"})
      {:ok, folder_a} = Storage.create_folder(%{name: "Shared name", parent_uuid: parent_a.uuid})
      {:ok, folder_b} = Storage.create_folder(%{name: "Shared name", parent_uuid: parent_b.uuid})
      {:ok, _} = GoodsIssues.set_storage_folder(issue_a, folder_a.uuid)
      {:ok, _} = GoodsIssues.set_storage_folder(issue_b, folder_b.uuid)

      put_hook(:goods_issue, nil)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :duplicate and &1.reason =~ "same destination"))
      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
    end

    test "a real hook still catches a genuine converging target when both sides are real movers" do
      issue_a = create_goods_issue!()
      issue_b = create_goods_issue!()

      {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
      {:ok, other} = Storage.create_folder(%{name: "Elsewhere"})
      {:ok, folder_a} = Storage.create_folder(%{name: "Renamed", parent_uuid: other.uuid})
      {:ok, folder_b} = Storage.create_folder(%{name: "Renamed"})

      {:ok, _} = GoodsIssues.set_storage_folder(issue_a, folder_a.uuid)
      {:ok, _} = GoodsIssues.set_storage_folder(issue_b, folder_b.uuid)

      put_hook(:goods_issue, target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :goods_issue and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.reason =~ "same destination"))
      refute is_nil(dup)
    end

    # U2 (head ruling): a no-op side (already sitting at the target) never
    # turns a genuine mover's move into a false `:duplicate` — this used to
    # be misreported as convergence merely because a stationary folder
    # shared the mover's desired name.
    test "one side already in place is not a converging competitor -> the real mover still gets a move" do
      issue_a = create_goods_issue!()
      issue_b = create_goods_issue!()

      {:ok, target} = Storage.create_folder(%{name: "Goods issues"})
      {:ok, folder_a} = Storage.create_folder(%{name: "Renamed", parent_uuid: target.uuid})
      {:ok, folder_b} = Storage.create_folder(%{name: "Renamed"})

      {:ok, _} = GoodsIssues.set_storage_folder(issue_a, folder_a.uuid)
      {:ok, _} = GoodsIssues.set_storage_folder(issue_b, folder_b.uuid)

      put_hook(:goods_issue, target.uuid)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :duplicate and &1.reason =~ "same destination"))
      move = Enum.find(actions, &(&1.kind == :goods_issue and &1.op == :move))
      refute is_nil(move)
      assert move.folder.uuid == folder_b.uuid
    end
  end
end
