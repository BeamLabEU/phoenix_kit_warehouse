defmodule PhoenixKitWarehouse.MediaReorganizer do
  @moduledoc """
  Warehouse's media-reorganizer plan source.

  Not compiled against a core `PhoenixKit.Modules.Storage.Reorganizer.Source`
  behaviour — today's hex core (2.23.x) does not ship the engine yet. This
  module declares no `@behaviour` and returns plain maps; see
  `PhoenixKitWarehouse.media_reorganizer/0` for the registration comment.
  Once core ships the engine, `plan/2`'s contract (`plan(actor_uuid, opts)
  :: [map()]`) already matches `Source.plan/2` — the only follow-up is
  adding `@behaviour`/`@impl`.

  Covers all six warehouse documents — `GoodsIssue`, `GoodsReceipt`,
  `InventoryDocument`, `SupplierOrder`, `InternalOrder`, `Transfer` — plus
  orphaned legacy document folders whose record is gone or soft-deleted
  (reported, never moved/trashed — see "Orphaned legacy folders" below).

  Unlike `PhoenixKitCatalogue.MediaReorganizer`, this module has:

    * a single hook, `:storage_parent_folder`
      (`PhoenixKitWarehouse.StorageFolders.parent_uuid_for/2`), and no
      separate folder-*name* hook — the desired name is always the
      deterministic `"<prefix>-<number-or-uuid>"` pattern
      (`PhoenixKitWarehouse.StorageFolders`'s private `folder_name/3`,
      reproduced here since it is not exported);
    * no pointer column on `InternalOrder` — its `after_move` is always
      `nil`, and its current folder is found by name only, never by
      pointer;
    * legacy names keyed by either a `number` (once the document has one)
      or a `uuid` (fallback), never a uuid alone — orphan detection has to
      try both;
    * no `<prefix>-attachment-pending-*` staging folders at all — nothing
      is staged before the document exists, so this Source has no
      `:pending` action kind.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitWarehouse.{GoodsIssue, GoodsIssues}
  alias PhoenixKitWarehouse.{GoodsReceipt, GoodsReceipts}
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.{Inventories, InventoryDocument}
  alias PhoenixKitWarehouse.StorageFolders
  alias PhoenixKitWarehouse.{SupplierOrder, SupplierOrders}
  alias PhoenixKitWarehouse.{Transfer, Transfers}

  @source "warehouse"

  # {kind, legacy name prefix, schema module} — the six document resources,
  # in the same order `StorageFolders`'s moduledoc lists them.
  @resources [
    {:goods_issue, "goods-issue", GoodsIssue},
    {:goods_receipt, "goods-receipt", GoodsReceipt},
    {:inventory, "inventory", InventoryDocument},
    {:supplier_order, "supplier-order", SupplierOrder},
    {:internal_order, "internal-order", InternalOrder},
    {:transfer, "transfer", Transfer}
  ]

  @doc """
  Builds the warehouse's reorganizer plan: one `:move` action per live
  document whose current folder does not already match `StorageFolders`'s
  own parent hook and deterministic name, plus a `:report` (`kind: :orphan`)
  per legacy-named folder whose document is gone or soft-deleted.

  `opts` is accepted for signature parity with the engine's `Source.plan/2`
  contract; this module has nothing to key off `opts[:pending_days]` — it
  stages no pending folders.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, _opts \\ []) do
    desired = resolve_desired(actor_uuid)

    resource_actions(desired) ++ orphan_actions(desired)
  end

  # ── Documents ────────────────────────────────────────────────────

  # `StorageFolders.parent_uuid_for/2` is record-independent (kind,
  # actor_uuid only) — resolved once per kind here rather than once per
  # record, so a host hook that does I/O pays for six calls, not one per
  # document.
  defp resolve_desired(actor_uuid) do
    parents_by_kind =
      Map.new(@resources, fn {kind, _prefix, _schema} ->
        {kind, StorageFolders.parent_uuid_for(kind, actor_uuid)}
      end)

    Enum.flat_map(@resources, fn {kind, prefix, schema} ->
      schema
      |> where([r], is_nil(r.deleted_at))
      |> repo().all()
      |> Enum.map(&build_desired(&1, kind, prefix, Map.fetch!(parents_by_kind, kind)))
    end)
  end

  defp build_desired(record, kind, prefix, parent_uuid) do
    %{
      record: record,
      kind: kind,
      parent_uuid: parent_uuid,
      name: legacy_name(prefix, record),
      pointer: pointer_uuid(kind, record)
    }
  end

  defp pointer_uuid(:internal_order, _record), do: nil
  defp pointer_uuid(_kind, record), do: record.storage_folder_uuid

  # Reproduces `StorageFolders`'s private `folder_name/3` — no host hook is
  # involved in naming, so this is plain formatting, not a rule this module
  # could resolve through a public call.
  defp legacy_name(prefix, record) do
    case record.number do
      n when (is_binary(n) and n != "") or is_integer(n) -> "#{prefix}-#{n}"
      _ -> "#{prefix}-#{record.uuid}"
    end
  end

  # Every folder lookup for the whole batch runs as three preloaded queries
  # (pointer uuids, legacy names at root, legacy names under a parent)
  # instead of one-to-three round trips per record.
  defp resource_actions(desired) do
    by_pointer = preload_by_uuid(Enum.map(desired, & &1.pointer))
    by_root_name = preload_by_root_name(Enum.map(desired, & &1.name))
    by_parent_name = preload_by_parent_name(desired)

    desired
    |> Enum.map(&resource_action(&1, by_pointer, by_root_name, by_parent_name))
    |> Enum.reject(&is_nil/1)
  end

  defp resource_action(desired, by_pointer, by_root_name, by_parent_name) do
    %{record: record, kind: kind, parent_uuid: parent_uuid, name: name} = desired

    case current_folder(desired, by_pointer, by_root_name, by_parent_name) do
      nil ->
        nil

      %Folder{} = folder ->
        after_move = after_move_fun(kind, record, desired.pointer, folder)

        if noop_move?(folder, parent_uuid, name) and is_nil(after_move) do
          nil
        else
          %{
            source: @source,
            kind: kind,
            label: name,
            op: :move,
            folder: folder,
            parent_uuid: parent_uuid,
            name: name,
            counts: counts(folder.uuid),
            on_conflict: :suffix,
            after_move: after_move
          }
        end
    end
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or an
  # accepted `"name (N)"` suffix variant) is a no-op — filtered here since
  # this Source has no core `Action.noop?/1` to lean on. A pointer
  # back-fill still needs the action even when the folder itself would not
  # move (`after_move_fun/4` is checked by the caller).
  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/^#{Regex.escape(name)} \(\d+\)$/, folder_name)
  end

  # One query for every distinct pointer uuid in the batch.
  defp preload_by_uuid(uuids) do
    case Enum.reject(Enum.uniq(uuids), &is_nil/1) do
      [] -> %{}
      uuids -> Folder |> where([f], f.uuid in ^uuids) |> repo().all() |> Map.new(&{&1.uuid, &1})
    end
  end

  # One query for every distinct legacy name in the batch, at root.
  defp preload_by_root_name(names) do
    case Enum.reject(Enum.uniq(names), &is_nil/1) do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.parent_uuid))
        |> repo().all()
        |> Map.new(&{&1.name, &1})
    end
  end

  # One query for every distinct legacy name under every distinct resolved
  # parent in the batch — still one round trip for the whole batch.
  defp preload_by_parent_name(desired) do
    names = desired |> Enum.map(& &1.name) |> Enum.uniq()
    parents = desired |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if names == [] or parents == [] do
      %{}
    else
      Folder
      |> where([f], f.name in ^names and f.parent_uuid in ^parents)
      |> repo().all()
      |> Map.new(&{{&1.name, &1.parent_uuid}, &1})
    end
  end

  # Pointer, if it still resolves to a live folder (never for InternalOrder —
  # it has no pointer field, so `desired.pointer` is always nil); else the
  # legacy deterministic name at root; else the legacy name under the
  # resolved parent. `nil` when none of those exist — nothing to move.
  defp current_folder(desired, by_pointer, by_root_name, by_parent_name) do
    %{name: name, parent_uuid: parent_uuid, pointer: pointer} = desired

    live_or_nil(pointer && Map.get(by_pointer, pointer)) ||
      live_or_nil(Map.get(by_root_name, name)) ||
      (parent_uuid && live_or_nil(Map.get(by_parent_name, {name, parent_uuid})))
  end

  defp live_or_nil(%Folder{trashed_at: nil} = folder), do: folder
  defp live_or_nil(_), do: nil

  defp after_move_fun(:internal_order, _record, _pointer, _folder), do: nil

  # `nil` when the pointer already matches the current (pre-move) folder —
  # nothing to back-fill. Otherwise a fun the engine runs after the move,
  # inside the same transaction, to write/repair the pointer.
  defp after_move_fun(kind, record, pointer, %Folder{uuid: folder_uuid}) do
    if pointer == folder_uuid do
      nil
    else
      fn -> write_pointer(kind, record, folder_uuid) end
    end
  end

  defp write_pointer(kind, record, folder_uuid) do
    case setter_for(kind).(record, folder_uuid) do
      {:ok, _updated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp setter_for(:goods_issue), do: &GoodsIssues.set_storage_folder/2
  defp setter_for(:goods_receipt), do: &GoodsReceipts.set_storage_folder/2
  defp setter_for(:inventory), do: &Inventories.set_storage_folder/2
  defp setter_for(:supplier_order), do: &SupplierOrders.set_storage_folder/2
  defp setter_for(:transfer), do: &Transfers.set_storage_folder/2

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`goods-issue-<number-or-uuid>`, etc.) at the
  # media root or under a parent this batch's hook resolved to, whose key
  # no longer names a live document (missing, or the document exists but
  # was soft-deleted — same `deleted_at` rule `resolve_desired/1` uses to
  # drop it from the plan) is reported so a host can collect it. Never
  # `:move`d or `:trash`ed here — this module owns no "orphans" container;
  # a legacy folder that IS a live document's current folder is left to
  # `resource_action/4` above. Reuses `desired`'s `parent_uuid`s (already
  # resolved once per record in `plan/2`) rather than calling the host hook
  # again.
  defp orphan_actions(desired) do
    resolved_parents =
      desired |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        records_by_key = load_candidate_records(candidates)

        candidates
        |> Enum.map(&orphan_action(&1, records_by_key))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One query for every legacy-named folder at root or under a resolved
  # parent — not a query per folder.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> repo().all()
    |> Enum.map(&{&1, legacy_kind_match(&1.name)})
    |> Enum.filter(fn {_folder, match} -> match end)
  end

  @legacy_prefixes for {kind, prefix, _schema} <- @resources, do: {prefix <> "-", kind}

  # The suffix after the prefix is either a `number` (once the document has
  # one) or a `uuid` (the fallback used before it does) — never a uuid
  # alone the way catalogue's legacy names are, so both are tried.
  defp legacy_kind_match(name) do
    Enum.find_value(@legacy_prefixes, &prefix_match(name, &1))
  end

  defp prefix_match(name, {prefix, kind}) do
    if String.starts_with?(name, prefix) do
      name |> String.replace_prefix(prefix, "") |> parse_key() |> wrap_match(kind)
    end
  end

  defp wrap_match(nil, _kind), do: nil
  defp wrap_match(key, kind), do: {kind, key}

  defp parse_key(suffix) do
    case Ecto.UUID.cast(suffix) do
      {:ok, uuid} ->
        {:uuid, uuid}

      :error ->
        case Integer.parse(suffix) do
          {number, ""} -> {:number, number}
          _ -> nil
        end
    end
  end

  # One query per {kind, key_type} group present among the candidates — not
  # a query per folder.
  defp load_candidate_records(candidates) do
    candidates
    |> Enum.group_by(
      fn {_folder, {kind, {key_type, _key}}} -> {kind, key_type} end,
      fn {_folder, {_kind, {_key_type, key}}} -> key end
    )
    |> Enum.reduce(%{}, fn {{kind, key_type}, keys}, acc ->
      Map.merge(acc, load_records(kind, key_type, Enum.uniq(keys)))
    end)
  end

  defp load_records(kind, :uuid, uuids) do
    kind
    |> schema_for()
    |> where([r], r.uuid in ^uuids)
    |> repo().all()
    |> Map.new(&{{kind, {:uuid, &1.uuid}}, &1})
  end

  defp load_records(kind, :number, numbers) do
    kind
    |> schema_for()
    |> where([r], r.number in ^numbers)
    |> repo().all()
    |> Map.new(&{{kind, {:number, &1.number}}, &1})
  end

  defp schema_for(kind), do: Enum.find_value(@resources, fn {k, _p, s} -> k == kind && s end)

  defp orphan_action({folder, {kind, key}}, records_by_key) do
    case Map.get(records_by_key, {kind, key}) do
      %{deleted_at: nil} ->
        nil

      record ->
        counts = counts(folder.uuid)

        %{
          source: @source,
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: counts,
          reason: orphan_reason(record, counts)
        }
    end
  end

  defp orphan_reason(nil, {files, _links}), do: "record missing, #{files} file(s)"

  defp orphan_reason(%{status: status}, {files, _links}),
    do: "record deleted (status #{status}), #{files} file(s)"

  # ── Shared helpers ───────────────────────────────────────────────

  # Counts ALL rows regardless of status (including trashed files) — the
  # core engine re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time
  # count that excluded trashed files would fail every folder holding one.
  defp counts(folder_uuid) do
    files =
      File
      |> where([f], f.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    links =
      FolderLink
      |> where([l], l.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    {files, links}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
