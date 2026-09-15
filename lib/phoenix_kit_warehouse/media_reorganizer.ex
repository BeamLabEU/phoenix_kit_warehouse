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

  A host that has not configured `:storage_parent_folder` is left entirely
  untouched: no move, no pointer back-fill — the hook is never even called.
  Orphan folders at the media root are still reported regardless (finding
  them needs no hook).

  ## Move planning

  For each live document (across all six kinds):

  1. A *candidate kind* is one with a live pointer among its documents, or a
     live folder anywhere named after its legacy pattern
     (`<prefix>-<number-or-uuid>`, resolved without calling any hook — one
     SQL-`LIKE`-filtered query for the whole plan). The `:storage_parent_folder`
     hook (2-arity, `resource`/`actor_uuid` — no record subject) is resolved
     **once per candidate kind**, never for a kind with nothing to move and
     never once per record.
  2. A document's *current* folder is: its live pointer if it has one (kept
     as-is, `name: nil` — the owner may have renamed it, this module never
     renames a cached folder); else the legacy-named live folder under the
     resolved parent; else the legacy-named live folder at root (the same
     order `StorageFolders.find_or_create/3` checks). A legacy name live in
     **both** places is unresolvable — reported as one `kind: :duplicate`
     action naming both folders, nothing moved.
  3. Two (or more) documents whose current folder resolves to the very same
     live folder are likewise unresolvable — one `kind: :duplicate` report
     per shared folder, no move for any of them.

  Unlike `PhoenixKitCatalogue.MediaReorganizer`, this module has:

    * a single hook, `:storage_parent_folder`
      (`PhoenixKitWarehouse.StorageFolders.parent_uuid_for/2`), and no
      separate folder-*name* hook — the desired name is always the
      deterministic `"<prefix>-<number-or-uuid>"` pattern
      (`PhoenixKitWarehouse.StorageFolders.folder_name/3`);
    * no pointer column on `InternalOrder` — its `after_move` is always
      `nil`, and its current folder is found by name only, never by
      pointer;
    * legacy names keyed by either a `number` (once the document has one)
      or a `uuid` (fallback), never a uuid alone — orphan detection has to
      try both, with the numeric form range-checked before it is ever bound
      into a query (a huge suffix is simply not a document id, not a crash);
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

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @bigint_min -9_223_372_036_854_775_808
  @bigint_max 9_223_372_036_854_775_807

  @doc """
  Builds the warehouse's reorganizer plan: one `:move` action per live
  document whose current folder does not already match `StorageFolders`'s
  own parent hook and deterministic name, `:report` (`kind: :duplicate`)
  actions for folders that cannot be unambiguously resolved, plus a
  `:report` (`kind: :orphan`) per legacy-named folder whose document is gone
  or soft-deleted.

  `opts` is accepted for signature parity with the engine's `Source.plan/2`
  contract; this module has nothing to key off `opts[:pending_days]` — it
  stages no pending folders.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, _opts \\ []) do
    {resource_actions, resolved_parents, legacy_candidates} = resource_plan(actor_uuid)

    resource_actions ++ orphan_actions(resolved_parents, legacy_candidates)
  end

  # ── Documents ────────────────────────────────────────────────────

  defp resource_plan(actor_uuid) do
    legacy_candidates = legacy_folder_candidates()

    if hook_configured?() do
      build_resource_plan(actor_uuid, legacy_candidates)
    else
      {[], [], legacy_candidates}
    end
  end

  defp hook_configured? do
    match?(
      {mod, fun} when is_atom(mod) and is_atom(fun),
      Application.get_env(:phoenix_kit_warehouse, :storage_parent_folder)
    )
  end

  # Candidate detection needs no hook call: a live pointer (uuid lookup) or
  # a live folder anywhere named after a document's legacy pattern (which
  # also covers a kind with zero live documents but a residual/orphan
  # folder — X13). Only kinds with at least one candidate go on to have the
  # host's parent hook resolved — once per kind, never once per record
  # (X12), and never for a kind with nothing to move.
  defp build_resource_plan(actor_uuid, legacy_candidates) do
    prelim = live_prelim_records()

    by_pointer = preload_by_uuid(Enum.map(prelim, & &1.pointer))
    by_name = group_by_name(legacy_candidates)

    kinds_with_pointer =
      prelim
      |> Enum.filter(fn p -> p.pointer && Map.has_key?(by_pointer, p.pointer) end)
      |> Enum.map(& &1.kind)
      |> MapSet.new()

    kinds_with_prefix_folder =
      legacy_candidates
      |> Enum.map(fn {_folder, {kind, _key}} -> kind end)
      |> MapSet.new()

    candidate_kinds = MapSet.union(kinds_with_pointer, kinds_with_prefix_folder)

    parents_by_kind =
      Map.new(candidate_kinds, fn kind ->
        {kind, StorageFolders.parent_uuid_for(kind, actor_uuid)}
      end)

    desired =
      prelim
      |> Enum.filter(&MapSet.member?(candidate_kinds, &1.kind))
      |> Enum.map(&Map.put(&1, :parent_uuid, Map.fetch!(parents_by_kind, &1.kind)))

    entries = Enum.map(desired, &resolve_entry(&1, by_pointer, by_name))

    {unique, ambiguous_dup, shared_dup} = classify_entries(entries)

    move_actions = unique |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1)
    dup_actions = Enum.map(ambiguous_dup, &build_ambiguous_duplicate_action/1)
    shared_actions = Enum.map(shared_dup, &build_shared_duplicate_action/1)

    all_actions = finalize_counts(move_actions ++ dup_actions ++ shared_actions)

    resolved_parents = parents_by_kind |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {all_actions, resolved_parents, legacy_candidates}
  end

  defp live_prelim_records do
    Enum.flat_map(@resources, fn {kind, prefix, schema} ->
      schema
      |> where([r], is_nil(r.deleted_at))
      |> repo().all()
      |> Enum.map(fn record ->
        %{
          record: record,
          kind: kind,
          pointer: pointer_uuid(kind, record),
          legacy_name: StorageFolders.folder_name(prefix, record.number, record.uuid)
        }
      end)
    end)
  end

  defp pointer_uuid(:internal_order, _record), do: nil
  defp pointer_uuid(_kind, record), do: record.storage_folder_uuid

  # Resolves one document's current folder. Pointer, when it names a live
  # folder (kept as-is downstream — D6: never renamed). Otherwise the
  # legacy name is looked up under the resolved parent, then at root
  # (`StorageFolders.find_or_create/3`'s own order); a live match at both
  # is ambiguous.
  defp resolve_entry(d, by_pointer, by_name) do
    pointer_folder = d.pointer && Map.get(by_pointer, d.pointer)

    if pointer_folder do
      Map.merge(d, %{folder: pointer_folder, via: :pointer, ambiguous: nil})
    else
      matches = Map.get(by_name, d.legacy_name, [])
      under_parent = d.parent_uuid && Enum.find(matches, &(&1.parent_uuid == d.parent_uuid))
      at_root = Enum.find(matches, &is_nil(&1.parent_uuid))

      case {under_parent, at_root} do
        {nil, nil} -> Map.merge(d, %{folder: nil, via: nil, ambiguous: nil})
        {same, same} -> Map.merge(d, %{folder: same, via: :name, ambiguous: nil})
        {f, nil} -> Map.merge(d, %{folder: f, via: :name, ambiguous: nil})
        {nil, f} -> Map.merge(d, %{folder: f, via: :name, ambiguous: nil})
        {f1, f2} -> Map.merge(d, %{folder: nil, via: nil, ambiguous: {f1, f2}})
      end
    end
  end

  # Splits resolved entries into: `unique` (one document ↔ one folder, safe
  # to plan a move for), `ambiguous_dup` (one document, legacy name live at
  # both root and under the resolved parent — X11), `shared_dup` (two or
  # more documents resolving to the very same live folder — X5). Every
  # entry in the two dup buckets becomes a `:report kind: :duplicate`
  # instead of a `:move`.
  defp classify_entries(entries) do
    {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
    {with_folder, _without_folder} = Enum.split_with(normal, & &1.folder)

    grouped = Enum.group_by(with_folder, & &1.folder.uuid)

    {shared, unique} =
      Enum.reduce(grouped, {[], []}, fn {_uuid, group}, {shared_acc, unique_acc} ->
        if length(group) > 1 do
          {[group | shared_acc], unique_acc}
        else
          {shared_acc, group ++ unique_acc}
        end
      end)

    {unique, ambiguous, shared}
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or
  # an accepted `"name (N)"` suffix variant) and needs no pointer back-fill
  # is a no-op — filtered here since this Source has no core
  # `Action.noop?/1` to lean on. D6: a folder found through the document's
  # pointer keeps `name: nil` (never renamed); only a folder found by
  # legacy name gets the desired name.
  defp build_move_action(%{via: :pointer} = entry), do: move_action(entry, nil)
  defp build_move_action(%{via: :name} = entry), do: move_action(entry, entry.legacy_name)

  defp move_action(
         %{record: record, kind: kind, folder: folder, parent_uuid: parent_uuid} = entry,
         name
       ) do
    after_move = after_move_fun(kind, record, entry.pointer, folder)

    if noop_move?(folder, parent_uuid, name) and is_nil(after_move) do
      nil
    else
      %{
        source: @source,
        kind: kind,
        label: folder.name,
        op: :move,
        folder: folder,
        parent_uuid: parent_uuid,
        name: name,
        counts: nil,
        on_conflict: :suffix,
        after_move: after_move
      }
    end
  end

  # `name: nil` (a pointer-found folder, D6) — this module never renames
  # it, so only the parent needs to match for the move to be a no-op.
  defp noop_move?(%Folder{parent_uuid: parent_uuid}, parent_uuid, nil), do: true
  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name)
       when is_binary(name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/^#{Regex.escape(name)} \(\d+\)$/, folder_name)
  end

  defp build_ambiguous_duplicate_action(%{legacy_name: legacy_name, ambiguous: {f1, f2}}) do
    %{
      source: @source,
      kind: :duplicate,
      label: legacy_name,
      op: :report,
      counts: nil,
      reason:
        "legacy folder found live in two places (#{f1.uuid} and #{f2.uuid}) — pick one and remove the other"
    }
  end

  defp build_shared_duplicate_action([%{folder: folder} | _] = group) do
    labels = group |> Enum.map(& &1.legacy_name) |> Enum.uniq() |> Enum.join(", ")

    %{
      source: @source,
      kind: :duplicate,
      label: folder.name,
      op: :report,
      counts: nil,
      reason: "folder #{folder.uuid} is claimed by more than one document: #{labels}"
    }
  end

  # One query for every distinct pointer uuid in the batch — live folders
  # only (X2, the unique index on (name, parent) is partial, so a trashed
  # folder must never hide a live one, and a pointer at a trashed folder
  # must be treated the same as no pointer at all).
  defp preload_by_uuid(uuids) do
    case Enum.reject(Enum.uniq(uuids), &is_nil/1) do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids and is_nil(f.trashed_at))
        |> repo().all()
        |> Map.new(&{&1.uuid, &1})
    end
  end

  defp group_by_name(legacy_candidates) do
    legacy_candidates
    |> Enum.map(fn {folder, _match} -> folder end)
    |> Enum.group_by(& &1.name)
  end

  defp after_move_fun(:internal_order, _record, _pointer, _folder), do: nil

  # `nil` when the pointer already matches the current (pre-move) folder —
  # nothing to back-fill. Otherwise a fun the engine runs after the move,
  # inside the same transaction, to write/repair the pointer. `set_storage_folder/2`
  # is a narrow single-column changeset + plain `repo().update()` — no
  # Activity log, no PubSub, no full-record validation (D7).
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

  # ── Legacy-named folders (shared by candidate detection and orphans) ──

  # One SQL-`LIKE`-filtered query (X6) for every live folder anywhere whose
  # name starts with one of the six legacy prefixes — used both to decide
  # which kinds have a candidate (X12/X13: a kind with a residual folder
  # but zero live documents still gets its parent hook resolved, so an
  # orphan under that parent is findable) and, filtered down to root/
  # resolved-parent scope, as the orphan candidate set itself. Live only
  # (X2).
  defp legacy_folder_candidates do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where(^legacy_prefix_condition())
    |> repo().all()
    |> Enum.map(&{&1, legacy_kind_match(&1.name)})
    |> Enum.filter(fn {_folder, match} -> match end)
  end

  defp legacy_prefix_condition do
    Enum.reduce(@resources, dynamic(false), fn {_kind, prefix, _schema}, acc ->
      dynamic([f], ^acc or like(f.name, ^"#{prefix}-%"))
    end)
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

  # X7: a strict UUID regex (36-char canonical form only) — not
  # `Ecto.UUID.cast/1`, which also accepts a raw 16-byte binary and would
  # key the map differently than the document's (lowercased) uuid. The
  # numeric form is range-checked against Postgres' bigint bounds before it
  # is ever bound into a query — an out-of-range suffix is simply not a
  # document id, not a `DBConnection.EncodeError`.
  defp parse_key(suffix) do
    if Regex.match?(@uuid_regex, suffix) do
      {:uuid, String.downcase(suffix)}
    else
      case Integer.parse(suffix) do
        {number, ""} when number >= @bigint_min and number <= @bigint_max -> {:number, number}
        _ -> nil
      end
    end
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`goods-issue-<number-or-uuid>`, etc.) at the
  # media root or under a parent this batch's hook resolved to, whose key
  # no longer names a live document (missing, or the document exists but
  # was soft-deleted) is reported so a host can collect it. Never `:move`d
  # or `:trash`ed here — this module owns no "orphans" container; a legacy
  # folder that IS a live document's current folder is left to
  # `build_move_action/1` above (its document resolves live, so it is
  # skipped below).
  defp orphan_actions(resolved_parents, legacy_candidates) do
    case Enum.filter(legacy_candidates, &orphan_scope?(&1, resolved_parents)) do
      [] ->
        []

      candidates ->
        records_by_key = load_candidate_records(candidates)
        counts = counts_by_folder(Enum.map(candidates, fn {folder, _match} -> folder.uuid end))

        candidates
        |> Enum.map(&orphan_action(&1, records_by_key, counts))
        |> Enum.reject(&is_nil/1)
    end
  end

  defp orphan_scope?({%Folder{parent_uuid: nil}, _match}, _resolved_parents), do: true

  defp orphan_scope?({%Folder{parent_uuid: parent_uuid}, _match}, resolved_parents),
    do: parent_uuid in resolved_parents

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

  defp orphan_action({folder, {kind, key}}, records_by_key, counts) do
    case Map.get(records_by_key, {kind, key}) do
      %{deleted_at: nil} ->
        nil

      record ->
        folder_counts = folder_counts(counts, folder.uuid)

        %{
          source: @source,
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: folder_counts,
          reason: orphan_reason(record, folder_counts)
        }
    end
  end

  defp orphan_reason(nil, {files, _links}), do: "record missing, #{files} file(s)"

  defp orphan_reason(%{status: status}, {files, _links}),
    do: "record deleted (status #{status}), #{files} file(s)"

  # ── Shared helpers ───────────────────────────────────────────────

  # X1: two grouped queries (files by folder_uuid, links by folder_uuid)
  # for a batch of folders — never a query per action. Counts ALL rows
  # regardless of status (including trashed files) — the core engine
  # re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time
  # count that excluded trashed files would fail every folder holding one.
  defp counts_by_folder(folder_uuids) do
    case Enum.uniq(folder_uuids) do
      [] ->
        {%{}, %{}}

      uuids ->
        files =
          File
          |> where([f], f.folder_uuid in ^uuids)
          |> group_by([f], f.folder_uuid)
          |> select([f], {f.folder_uuid, count(f.uuid)})
          |> repo().all()
          |> Map.new()

        links =
          FolderLink
          |> where([l], l.folder_uuid in ^uuids)
          |> group_by([l], l.folder_uuid)
          |> select([l], {l.folder_uuid, count(l.uuid)})
          |> repo().all()
          |> Map.new()

        {files, links}
    end
  end

  defp folder_counts({files, links}, folder_uuid) do
    {Map.get(files, folder_uuid, 0), Map.get(links, folder_uuid, 0)}
  end

  # Fills `counts: nil` placeholders left by `build_move_action/1` with a
  # single batched lookup across every `:move` action's folder — the
  # batch's move-folder counts come from one pair of grouped queries (X1),
  # not one pair per action. Duplicate-report actions carry no `:folder`
  # key and are left untouched (`counts: nil`, they report, never move).
  defp finalize_counts(actions) do
    counts =
      actions
      |> Enum.map(fn
        %{folder: %Folder{uuid: uuid}} -> uuid
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> counts_by_folder()

    Enum.map(actions, fn
      %{folder: %Folder{uuid: uuid}} = action -> %{action | counts: folder_counts(counts, uuid)}
      action -> action
    end)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
