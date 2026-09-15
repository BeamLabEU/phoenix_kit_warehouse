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

  Contract (design §9/§10 of `2026-09-15-media-reorganizer-design.md`):

    * **No configured `:storage_parent_folder` hook → `:report`-only (E1).**
      The hook itself is never called (the desired parent defaults to root,
      D1/§4) — but candidate resolution still runs: orphan, duplicate and
      relocated reports are still produced; only `:move` and any pointer
      back-fill it would carry are suppressed.
    * **Claims are hook-independent (R1).** Every live document's valid,
      live pointer folder is "claimed" regardless of whether the hook is
      configured or working — a folder any live document's pointer names is
      never reported as an orphan, even one whose name coincidentally
      matches another (deleted) document's legacy pattern.
    * **A hook that raises, exits, or returns anything but `{:ok, uuid}` or
      an explicit `nil`** is a hook FAILURE (R2): every candidate of that
      *kind* is skipped (no move planned) and counted into one
      `kind: :hook_error` report for the whole plan. `{:ok, uuid}` is only
      accepted once `uuid` casts as a well-formed UUID (T1) — a garbage or
      empty string is a failure too, never a literal parent to move a
      document into. A configured `{mod, fun}` that is not actually
      callable (typo, removed function) is the same kind of failure,
      reported once as "not callable" (T3), not silently treated as no
      hook. Only an explicit `nil` means "root" — a transient failure is
      never planned as a move to root, and neither is an explicit `nil`
      for a document whose current folder already lives under a real
      parent (F1): the parent is kept as-is (only a pointer back-fill, if
      any, is still planned) and the document is counted into a separate
      `kind: :hook_nil` report instead.
    * A *candidate kind* is one with a live pointer among its documents, or
      a live folder anywhere named after its legacy pattern
      (`<prefix>-<number-or-uuid>`, resolved without calling any hook — one
      SQL-`LIKE`-filtered query for the whole plan). The `:storage_parent_folder`
      hook (2-arity, `resource`/`actor_uuid` — no record subject) is
      resolved **once per candidate kind**, never once per record and never
      for a kind with nothing to move.
    * A document's *current* folder is: its live pointer if it has one
      (kept as-is unless the folder still carries the exact legacy name,
      D6/E2 — the owner may have renamed it, this module never overwrites a
      renamed folder); else the legacy-named live folder under the resolved
      parent, then at root (the same order `StorageFolders.find_or_create/3`
      checks). A legacy name live in **both** places is unresolvable —
      reported as one `kind: :duplicate` action naming both folders,
      nothing moved. A legacy name live somewhere other than root or the
      resolved parent is left alone and reported `kind: :relocated` — never
      adopted.
    * Two (or more) documents whose current folder resolves to the very
      same live folder are likewise unresolvable — one `kind: :duplicate`
      report per shared folder, no move for any of them. Two documents with
      *different* current folders whose desired targets coincide (same
      resolved parent + name) are also reported `kind: :duplicate` instead
      of planning both moves (the second would collide with the first at
      apply time) — but only when a working hook is configured and only
      among documents that would actually move (F6): without a hook every
      candidate's desired parent defaults to root regardless of its real
      current parent, so a name collision computed from that default would
      be a false positive, and a document already sitting at its target
      (nothing to move) never turns another document's real move into a
      false "converging" pair.
    * A document whose current folder is resolved (via pointer or a
      name/parent match) can still leave SEPARATE legacy-named folder(s)
      live somewhere else entirely (e.g. an old third-party container) —
      every one of them (not only the first) is neither the document's
      current folder nor an orphan (the document is alive); each gets its
      own `kind: :relocated` report alongside whatever action the document
      itself gets, unless that folder is itself another document's claimed
      current folder (a claimed folder is never also reported
      `:relocated`).
    * `on_conflict: :suffix` for every kind that writes a pointer back;
      `internal_order` has no pointer column, so its `on_conflict: :report`
      (D3 — a renamed folder with nobody pointing at it would be orphaned).

  Unlike `PhoenixKitCatalogue.MediaReorganizer`, this module has:

    * a single hook, `:storage_parent_folder`
      (called directly by this module, not through
      `StorageFolders.parent_uuid_for/2` — that function's own
      hook-failure-becomes-root fallback is right for a fresh upload but
      wrong here, see R2 above), and no separate folder-*name* hook — the
      desired name is always the deterministic `"<prefix>-<number-or-uuid>"`
      pattern (`PhoenixKitWarehouse.StorageFolders.folder_name/3`);
    * no pointer column on `InternalOrder` — its `after_move` is always
      `nil`, and its current folder is found by name only, never by
      pointer;
    * legacy names keyed by either a `number` (once the document has one)
      or a `uuid` (fallback), never a uuid alone — orphan detection has to
      try both, with the numeric form matched by a strict digits-only,
      no-leading-zero regex and range-checked against Postgres' bigint
      bounds before it is ever bound into a query (a huge or malformed
      suffix is simply not a document id, not a crash);
    * no `<prefix>-attachment-pending-*` staging folders at all — nothing
      is staged before the document exists, so this Source has no
      `:pending` action kind.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}
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

  @pointer_kinds [:goods_issue, :goods_receipt, :inventory, :supplier_order, :transfer]

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  # F2: digits only, no leading zero, no sign — "690" is a document number,
  # "+690" / "00690" / "-1" are not (and must never be parsed as one).
  @number_regex ~r/\A[1-9]\d*\z/
  @bigint_min -9_223_372_036_854_775_808
  @bigint_max 9_223_372_036_854_775_807

  @doc """
  Builds the warehouse's reorganizer plan: one `:move` action per live
  document whose current folder does not already match `StorageFolders`'s
  own parent hook and deterministic name, `:report` actions
  (`kind: :duplicate | :relocated | :hook_error`) for anything that cannot
  be safely moved, plus a `:report` (`kind: :orphan`) per legacy-named
  folder whose document is gone or soft-deleted.

  `opts` is accepted for signature parity with the engine's `Source.plan/2`
  contract; this module has nothing to key off `opts[:pending_days]` — it
  stages no pending folders.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    _ = opts
    prelim = live_prelim_records()
    legacy_candidates = legacy_folder_candidates()

    # R1: hook-independent — a folder any live document's valid pointer
    # names is never a candidate for an orphan report, hook configured or
    # not, working or not.
    pointer_claims = live_pointer_claims(prelim)

    # E1: candidate resolution (pointer/legacy-name lookup, duplicate and
    # relocated detection) needs no hook at all — it runs unconditionally,
    # with the desired parent defaulting to root when no hook is
    # configured (D1/§4). Only `:move`/back-fill actions and hook-error
    # reports depend on a configured, callable hook; `build_resource_plan/5`
    # drops those itself when `hook_on?` is false. T3: a hook configured in
    # `{mod, fun}` shape but not actually callable is a distinct failure —
    # it still gets report-only treatment (like `:none`) PLUS one
    # `:hook_error` naming the problem, never silently "no hook".
    {resource_actions, resolved_parents, resolved_claims} =
      case hook_status() do
        :ok ->
          build_resource_plan(actor_uuid, prelim, legacy_candidates, pointer_claims, true)

        {:not_callable, mod, fun} ->
          {actions, parents, claims} =
            build_resource_plan(actor_uuid, prelim, legacy_candidates, pointer_claims, false)

          {[not_callable_hook_action(mod, fun) | actions], parents, claims}

        :none ->
          build_resource_plan(actor_uuid, prelim, legacy_candidates, pointer_claims, false)
      end

    claimed_uuids = MapSet.union(pointer_claims, resolved_claims)

    resource_actions ++ orphan_actions(resolved_parents, legacy_candidates, claimed_uuids)
  end

  # ── Documents ────────────────────────────────────────────────────

  # T3: a configured `{mod, fun}` that is not actually callable (a typo, a
  # removed function) is a distinct failure from "no hook configured at
  # all" — it must not silently degrade to report-only (E1) without telling
  # the owner why nothing moved.
  defp hook_status do
    case Application.get_env(:phoenix_kit_warehouse, :storage_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        if callable?(mod, fun), do: :ok, else: {:not_callable, mod, fun}

      _ ->
        :none
    end
  end

  defp callable?(mod, fun), do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2)

  defp not_callable_hook_action(mod, fun) do
    %{
      source: @source,
      kind: :hook_error,
      op: :report,
      label: "storage_parent_folder hook",
      counts: nil,
      reason: "configured parent hook {#{inspect(mod)}, #{inspect(fun)}} is not callable"
    }
  end

  # R9: only the columns a plan needs — never a full row (four of the six
  # schemas carry a `lines` jsonb column that can be large).
  defp light_fields(kind) when kind in @pointer_kinds,
    do: [:uuid, :number, :status, :storage_folder_uuid, :inserted_at]

  defp light_fields(:internal_order), do: [:uuid, :number, :status, :inserted_at]

  # R10: deterministic order — the six kinds in `@resources`'s own order,
  # each by inserted_at/uuid.
  # T6/R10: `order_index` records this global, deterministic position (kind
  # order, then inserted_at/uuid within a kind) so later grouping (shared /
  # converging duplicates) can re-sort its groups instead of inheriting a
  # `Map`'s undefined iteration order.
  defp live_prelim_records do
    @resources
    |> Enum.flat_map(fn {kind, prefix, schema} ->
      schema
      |> where([r], is_nil(r.deleted_at))
      |> order_by([r], asc: r.inserted_at, asc: r.uuid)
      |> select([r], struct(r, ^light_fields(kind)))
      |> repo().all()
      |> Enum.map(fn record ->
        %{
          record: record,
          kind: kind,
          pointer: valid_uuid(pointer_uuid(kind, record)),
          legacy_name: StorageFolders.folder_name(prefix, record.number, record.uuid)
        }
      end)
    end)
    |> Enum.with_index()
    |> Enum.map(fn {p, idx} -> Map.put(p, :order_index, idx) end)
  end

  defp pointer_uuid(:internal_order, _record), do: nil
  defp pointer_uuid(_kind, record), do: record.storage_folder_uuid

  # R5/X3: a pointer that is not a well-formed UUID is treated as absent,
  # never sent into an `in ^uuids` query. Returns the CAST/downcased value —
  # not the raw string — so an upper-case pointer still matches the
  # (lower-case) keys `by_pointer` and the live-claims set are keyed by.
  defp valid_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, cast} -> cast
      :error -> nil
    end
  end

  defp valid_uuid(_), do: nil

  # R1: every valid, live pointer of every LIVE document — independent of
  # whether the parent hook is configured or working. Used only to keep a
  # claimed folder out of the orphan sweep; never triggers a hook.
  defp live_pointer_claims(prelim) do
    pointers = prelim |> Enum.map(& &1.pointer) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Folder
    |> where([f], f.uuid in ^pointers and is_nil(f.trashed_at))
    |> select([f], f.uuid)
    |> repo().all()
    |> MapSet.new()
  end

  # Candidate detection needs no hook call: a live pointer (uuid lookup) or
  # a live folder anywhere named after a document's legacy pattern (which
  # also covers a kind with zero live documents but a residual/orphan
  # folder — X13). Only kinds with at least one candidate go on to have the
  # host's parent hook resolved — once per kind, never once per record
  # (X12), and never for a kind with nothing to move.
  defp build_resource_plan(actor_uuid, prelim, legacy_candidates, pointer_claims, hook_on?) do
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

    # E1: without a configured hook the desired parent is root for every
    # kind (D1/§4) — never call the hook (there is none), never a
    # hook-error candidate.
    {ok_parents, hook_error_kinds} =
      if hook_on? do
        resolve_parents(candidate_kinds, actor_uuid)
      else
        {Map.new(candidate_kinds, &{&1, nil}), MapSet.new()}
      end

    # T4: a document only actually needed the hook's answer if it, itself,
    # has a live pointer or a live folder under its own legacy name — a
    # document with neither (its kind is only a "candidate kind" because
    # SOME OTHER document of that kind has a folder) is never counted into
    # `:hook_error`'s "N document(s) skipped".
    candidates =
      Enum.filter(prelim, fn p ->
        MapSet.member?(candidate_kinds, p.kind) and
          ((p.pointer && Map.has_key?(by_pointer, p.pointer)) ||
             Map.has_key?(by_name, p.legacy_name))
      end)

    {ok_candidates, failed_candidates} =
      Enum.split_with(candidates, &(not MapSet.member?(hook_error_kinds, &1.kind)))

    desired =
      Enum.map(ok_candidates, &Map.put(&1, :parent_uuid, Map.fetch!(ok_parents, &1.kind)))

    entries =
      desired
      |> Enum.map(&resolve_entry(&1, by_pointer, by_name))
      |> apply_nil_root_guard(hook_on?)

    hook_nil_count = Enum.count(entries, & &1.hook_nil)

    # X11: a legacy name live at both root and under the resolved parent is
    # unresolvable — one `:duplicate` report, never a move for that
    # document; every OTHER live match for the same name is still a stray
    # twin (handled below, alongside `with_folder`/`without_folder`).
    {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
    {with_folder, without_folder} = Enum.split_with(normal, & &1.folder)

    {shared, unique} = split_shared(with_folder)

    # F6: converging-target detection only makes sense with a working hook
    # (without one, every candidate's desired parent defaults to root
    # regardless of its real current parent — a coincidental name match at
    # that default would be a false positive, P6) and only when the group
    # contains at least one document that would actually MOVE — a group
    # where every member already sits at the shared target has nothing to
    # collide with at apply time (also P6: without a hook, or with an
    # explicit nil for the whole group, nobody moves at all).
    {converging_groups, solo_candidates} =
      if hook_on?, do: split_converging(unique), else: {[], unique}

    {converging, non_colliding_groups} =
      Enum.split_with(converging_groups, &Enum.any?(&1, fn entry -> real_move?(entry) end))

    solo =
      Enum.sort_by(solo_candidates ++ List.flatten(non_colliding_groups), & &1.order_index)

    # E1: `:move` (and any pointer back-fill it carries) is only ever
    # planned when a hook is configured — a host without one is untouched,
    # even though the duplicate/relocated reports above still stand.
    move_actions =
      if hook_on?, do: solo |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1), else: []

    dup_actions = Enum.map(ambiguous, &build_ambiguous_duplicate_action/1)
    shared_actions = Enum.map(shared, &build_shared_duplicate_action/1)
    converging_actions = Enum.map(converging, &build_converging_duplicate_action/1)

    hook_error_actions =
      hook_error_action(length(failed_candidates), MapSet.size(hook_error_kinds))

    hook_nil_actions = hook_nil_action(hook_nil_count)

    claimed = claimed_folder_uuids(solo, ambiguous, shared, converging)
    all_claimed = MapSet.union(claimed, pointer_claims)

    # T5: every live legacy-named copy other than a document's own adopted
    # current folder gets its own `:relocated` report — all of them, not
    # only the first — except a copy that is itself another document's
    # claimed (adopted) folder, which is never also reported `:relocated`.
    stray_actions =
      Enum.flat_map(with_folder ++ without_folder, &stray_relocated_actions(&1, all_claimed))

    all_actions =
      finalize_counts(
        move_actions ++
          dup_actions ++
          shared_actions ++
          converging_actions ++ stray_actions ++ hook_error_actions ++ hook_nil_actions
      )

    resolved_parents =
      if hook_on?,
        do: ok_parents |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.uniq(),
        else: []

    {all_actions, resolved_parents, claimed}
  end

  # R2: resolves the desired parent for every candidate *kind* via the
  # host's exact hook, distinguishing an explicit `nil` (root) from a hook
  # that raised/exited/returned anything else (failure — every candidate of
  # that kind is skipped, never treated as "root").
  defp resolve_parents(candidate_kinds, actor_uuid) do
    {mod, fun} = Application.get_env(:phoenix_kit_warehouse, :storage_parent_folder)

    Enum.reduce(candidate_kinds, {%{}, MapSet.new()}, fn kind, {oks, errs} ->
      case guarded_hook_call(mod, fun, kind, actor_uuid) do
        {:ok, uuid} -> {Map.put(oks, kind, uuid), errs}
        :error -> {oks, MapSet.put(errs, kind)}
      end
    end)
  end

  # T1: every answer is cast through `Ecto.UUID.cast/1` and downcased —
  # `{:ok, ""}` / `{:ok, "not-a-uuid"}` are hook FAILURES (`:error`), never
  # sent into a later `in ^uuids` query (which would raise a CastError and
  # take down the whole plan). F2/T4-adjacent: exceptions and non-local
  # exits are logged with the module and kind so a failure is diagnosable.
  defp guarded_hook_call(mod, fun, kind, actor_uuid) do
    case apply(mod, fun, [kind, actor_uuid]) do
      {:ok, uuid} when is_binary(uuid) ->
        case valid_uuid(uuid) do
          nil -> :error
          cast -> {:ok, cast}
        end

      {:ok, nil} ->
        {:ok, nil}

      nil ->
        {:ok, nil}

      _other ->
        :error
    end
  rescue
    error ->
      Logger.warning(
        "storage_parent_folder hook #{inspect(mod)}.#{fun} raised for kind #{inspect(kind)}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  catch
    catch_kind, reason ->
      Logger.warning(
        "storage_parent_folder hook #{inspect(mod)}.#{fun} #{catch_kind} for kind " <>
          "#{inspect(kind)}: #{inspect(reason)}"
      )

      :error
  end

  defp hook_error_action(0, 0), do: []

  defp hook_error_action(doc_count, kind_count) do
    [
      %{
        source: @source,
        kind: :hook_error,
        op: :report,
        label: "storage_parent_folder hook",
        counts: nil,
        reason: hook_error_reason(doc_count, kind_count)
      }
    ]
  end

  # T4: reported even when the failure only affects a kind's orphan scan
  # (a kind with a residual folder but zero live documents — X13) and
  # `doc_count` would otherwise be 0.
  defp hook_error_reason(0, kind_count) do
    "#{kind_count} kind(s)' orphan scan skipped: the configured parent hook raised, " <>
      "exited, or returned neither {:ok, uuid} nor nil"
  end

  defp hook_error_reason(doc_count, _kind_count) do
    "#{doc_count} document(s) skipped: the configured parent hook raised, exited, or " <>
      "returned neither {:ok, uuid} nor nil"
  end

  # F1: an explicit `nil`/`{:ok, nil}` answer from the parent hook never
  # pulls a folder that currently lives under a real parent out to root —
  # only a pointer back-fill (if any) is kept, and the parent/name stay
  # exactly as they are (no rename either, since the desired name isn't
  # being applied). Named/pointer resolution above already guarantees
  # `entry.folder` is the document's actual current folder when set, so
  # this is safe regardless of resolution route. Skipped entirely without a
  # working hook (`hook_on?` false) — `:move` is suppressed for every entry
  # in that case anyway (E1), and the default-to-root parent there is a
  # deliberate design default, not a hook answering "root".
  defp apply_nil_root_guard(entries, false), do: Enum.map(entries, &Map.put(&1, :hook_nil, false))
  defp apply_nil_root_guard(entries, true), do: Enum.map(entries, &apply_nil_root_guard/1)

  defp apply_nil_root_guard(%{folder: %Folder{parent_uuid: parent_uuid}} = entry)
       when not is_nil(parent_uuid) and is_nil(entry.parent_uuid) do
    entry
    |> Map.put(:parent_uuid, parent_uuid)
    |> Map.put(:name, nil)
    |> Map.put(:hook_nil, true)
  end

  defp apply_nil_root_guard(entry), do: Map.put(entry, :hook_nil, false)

  defp hook_nil_action(0), do: []

  defp hook_nil_action(count) do
    [
      %{
        source: @source,
        kind: :hook_nil,
        op: :report,
        label: "storage_parent_folder hook",
        counts: nil,
        reason:
          "#{count} document(s): the parent hook answered root for a folder living under a " <>
            "parent — left in place"
      }
    ]
  end

  # Resolves one document's current folder. Pointer, when it names a live
  # folder — kept as-is (D6) unless it still carries the exact legacy name,
  # in which case it's safe to apply the (identical) deterministic name
  # (E2). Otherwise the legacy name is looked up under the resolved parent,
  # then at root (`StorageFolders.find_or_create/3`'s own order); a live
  # match at both is ambiguous; a live match anywhere else is a stray twin,
  # reported `:relocated`.
  defp resolve_entry(d, by_pointer, by_name) do
    pointer_folder = d.pointer && Map.get(by_pointer, d.pointer)

    if pointer_folder do
      resolve_pointer_entry(d, pointer_folder, by_name)
    else
      resolve_name_entry(d, by_name)
    end
  end

  defp resolve_pointer_entry(d, folder, by_name) do
    name = if folder.name == d.legacy_name, do: d.legacy_name
    stray_legacy = stray_legacy_matches(d.legacy_name, by_name, folder.uuid)

    Map.merge(d, %{
      folder: folder,
      via: :pointer,
      name: name,
      ambiguous: nil,
      stray_legacy: stray_legacy
    })
  end

  # T5: every live match for the legacy name other than the document's own
  # current folder — a list, not just the first one.
  defp stray_legacy_matches(legacy_name, by_name, current_folder_uuid) do
    by_name
    |> Map.get(legacy_name, [])
    |> Enum.reject(&(&1.uuid == current_folder_uuid))
  end

  defp resolve_name_entry(d, by_name) do
    matches = Map.get(by_name, d.legacy_name, [])
    under_parent = d.parent_uuid && Enum.find(matches, &(&1.parent_uuid == d.parent_uuid))
    at_root = Enum.find(matches, &is_nil(&1.parent_uuid))
    picked = under_parent || at_root

    # T5: every OTHER live match — all of them, not only the first — once
    # `picked` (if any) is accounted for.
    stray_legacy = Enum.reject(matches, &(&1 == picked))

    cond do
      under_parent && at_root ->
        Map.merge(d, %{
          folder: nil,
          via: nil,
          name: nil,
          ambiguous: {under_parent, at_root},
          stray_legacy: []
        })

      picked ->
        Map.merge(d, %{
          folder: picked,
          via: :name,
          name: d.legacy_name,
          ambiguous: nil,
          stray_legacy: stray_legacy
        })

      true ->
        # Nothing resolves as the current folder at all — every live match
        # is a stray copy, reported `:relocated` (T5: every one of them).
        Map.merge(d, %{folder: nil, via: nil, name: nil, ambiguous: nil, stray_legacy: matches})
    end
  end

  # T5: a live legacy-named copy of a document other than its adopted
  # current folder — one `:relocated` report per copy, all of them, never
  # just the first. A copy that is itself claimed by another document (its
  # own resolved current folder, or another duplicate/converging group) is
  # excluded — a claimed folder is never also reported `:relocated`.
  defp stray_relocated_actions(entry, claimed) do
    entry.stray_legacy
    |> Enum.reject(&MapSet.member?(claimed, &1.uuid))
    |> Enum.map(
      &build_relocated_action(%{legacy_name: entry.legacy_name, kind: entry.kind, relocated: &1})
    )
  end

  # Order-preserving (R10/T6) grouping — `Map.values/1` after `group_by`
  # does not preserve insertion order (a `Map`'s iteration order is
  # unrelated to insertion order), so every group is re-sorted by its
  # earliest member's `order_index`.
  defp split_shared(entries) do
    freq = Enum.frequencies_by(entries, & &1.folder.uuid)
    {shared_entries, unique} = Enum.split_with(entries, &(Map.get(freq, &1.folder.uuid) > 1))
    shared_groups = shared_entries |> Enum.group_by(& &1.folder.uuid) |> Map.values()
    {sort_groups(shared_groups), unique}
  end

  # F6/R7/E3: two documents whose *desired* target (parent + name, or
  # parent + the folder's own kept name when `name` is nil) coincide — the
  # second move would collide with the first at apply time. Only called
  # with documents that would actually move (see `build_resource_plan/5`).
  defp split_converging(entries) do
    freq = Enum.frequencies_by(entries, &convergence_key/1)

    {converging_entries, solo} =
      Enum.split_with(entries, &(Map.get(freq, convergence_key(&1)) > 1))

    converging_groups = converging_entries |> Enum.group_by(&convergence_key/1) |> Map.values()
    {sort_groups(converging_groups), solo}
  end

  defp sort_groups(groups) do
    Enum.sort_by(groups, fn group -> group |> Enum.map(& &1.order_index) |> Enum.min() end)
  end

  defp convergence_key(entry), do: {entry.parent_uuid, entry.name || entry.folder.name}

  # A document whose current folder already sits at its desired target and
  # needs no pointer back-fill has nothing to move — it can never collide
  # with anything at apply time, so it is excluded from convergence
  # detection (F6). Mirrors the no-op check `build_move_action/1` applies.
  defp real_move?(entry) do
    after_move = after_move_fun(entry.kind, entry.record, entry.pointer, entry.folder)
    not (noop_move?(entry.folder, entry.parent_uuid, entry.name) and is_nil(after_move))
  end

  defp claimed_folder_uuids(unique, ambiguous, shared_groups, converging_groups) do
    unique_uuids = Enum.map(unique, & &1.folder.uuid)

    ambiguous_uuids =
      Enum.flat_map(ambiguous, fn %{ambiguous: {f1, f2}} -> [f1.uuid, f2.uuid] end)

    shared_uuids = Enum.flat_map(shared_groups, fn [%{folder: f} | _] -> [f.uuid] end)

    converging_uuids =
      Enum.flat_map(converging_groups, fn group -> Enum.map(group, & &1.folder.uuid) end)

    MapSet.new(unique_uuids ++ ambiguous_uuids ++ shared_uuids ++ converging_uuids)
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` and
  # needs no pointer back-fill is a no-op — filtered here since this Source
  # has no core `Action.noop?/1` to lean on. A folder resolved via name
  # (`entry.name == entry.legacy_name`, matched exactly by `by_name`) or via
  # a kept pointer name always already carries the desired name when found,
  # so only the parent can differ — there is no suffixed-variant case to
  # detect here (unlike catalogue, which has a separate name hook).
  defp build_move_action(entry) do
    move_action(entry, entry.name)
  end

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
        on_conflict: on_conflict_for(kind),
        after_move: after_move
      }
    end
  end

  # D3: only a Source that writes a pointer back can safely rename on
  # collision — `internal_order` has no pointer column, so a renamed folder
  # would be orphaned; it reports instead.
  defp on_conflict_for(:internal_order), do: :report
  defp on_conflict_for(_kind), do: :suffix

  defp noop_move?(%Folder{parent_uuid: parent_uuid}, parent_uuid, nil), do: true
  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true
  defp noop_move?(_folder, _parent_uuid, _name), do: false

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

  defp build_converging_duplicate_action([entry | _] = group) do
    labels = group |> Enum.map(& &1.legacy_name) |> Enum.uniq() |> Enum.join(", ")
    {parent_uuid, name} = convergence_key(entry)
    parent_label = parent_uuid || "root"

    %{
      source: @source,
      kind: :duplicate,
      label: labels,
      op: :report,
      counts: nil,
      reason:
        "multiple documents would move to the same destination (parent #{parent_label}, name #{name}): #{labels}"
    }
  end

  # T5: the reason names the copy's ACTUAL place — a stray copy can itself
  # be at root (e.g. the document's current folder was found via pointer,
  # elsewhere), so "under a different parent" would be a false description
  # for it.
  defp build_relocated_action(%{legacy_name: legacy_name, kind: kind, relocated: folder}) do
    %{
      source: @source,
      kind: :relocated,
      op: :report,
      label: legacy_name,
      folder: folder,
      counts: nil,
      reason:
        "legacy folder #{folder.uuid} (#{kind}) is live #{relocated_place(folder)} — left alone, never adopted"
    }
  end

  defp relocated_place(%Folder{parent_uuid: nil}), do: "at the storage root"
  defp relocated_place(%Folder{}), do: "under a different parent"

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
  # inside the same transaction, to write/repair the pointer.
  defp after_move_fun(kind, record, pointer, %Folder{uuid: folder_uuid}) do
    if pointer == folder_uuid do
      nil
    else
      fn -> write_pointer(kind, record, folder_uuid) end
    end
  end

  # Re-checks the document under `FOR UPDATE` at apply time: gone or
  # soft-deleted since the plan was built aborts the back-fill instead of
  # pointing a live-looking document at a folder nobody will ever see
  # again, and picks up a pointer `ensure_for_*` may have set concurrently
  # between plan and apply. `set_storage_folder/2` is a narrow
  # single-column changeset + plain `repo().update()` — no Activity log, no
  # PubSub, no full-record validation (D7).
  defp write_pointer(kind, record, folder_uuid) do
    case locked_record(kind, record.uuid) do
      nil ->
        {:error, :not_found}

      %{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        {:error, :record_deleted}

      current ->
        case setter_for(kind).(current, folder_uuid) do
          {:ok, _updated} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp locked_record(kind, uuid) do
    kind
    |> schema_for()
    |> where([r], r.uuid == ^uuid)
    |> lock("FOR UPDATE")
    |> repo().one()
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
  # T6: deterministic order — the same `order_by` the rest of this module's
  # candidate queries use.
  defp legacy_folder_candidates do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where(^legacy_prefix_condition())
    |> order_by([f], asc: f.inserted_at, asc: f.uuid)
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
  # key the map differently than the document's (lowercased) uuid. F2: the
  # numeric form must be digits-only with no leading zero and no sign
  # before it is even considered a number, and is then range-checked
  # against Postgres' bigint bounds before it is ever bound into a query —
  # an out-of-range or malformed suffix is simply not a document id, not a
  # `DBConnection.EncodeError`.
  defp parse_key(suffix) do
    cond do
      Regex.match?(@uuid_regex, suffix) ->
        {:uuid, String.downcase(suffix)}

      Regex.match?(@number_regex, suffix) ->
        case Integer.parse(suffix) do
          {number, ""} when number >= @bigint_min and number <= @bigint_max -> {:number, number}
          _ -> nil
        end

      true ->
        nil
    end
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`goods-issue-<number-or-uuid>`, etc.) at the
  # media root or under a parent this batch's hook resolved to, whose key
  # no longer names a live document (missing, or the document exists but
  # was soft-deleted), and which is not the current folder of some other
  # resolved document (R4 — one folder gets at most one action; a folder
  # claimed via a pointer whose name coincidentally matches a different,
  # deleted document's legacy pattern must never also become an orphan
  # report), is reported so a host can collect it. Never `:move`d or
  # `:trash`ed here — this module owns no "orphans" container.
  defp orphan_actions(resolved_parents, legacy_candidates, claimed_uuids) do
    case Enum.filter(legacy_candidates, &orphan_scope?(&1, resolved_parents, claimed_uuids)) do
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

  defp orphan_scope?({folder, _match}, resolved_parents, claimed_uuids) do
    not MapSet.member?(claimed_uuids, folder.uuid) and
      in_resolved_scope?(folder, resolved_parents)
  end

  defp in_resolved_scope?(%Folder{parent_uuid: nil}, _resolved_parents), do: true

  defp in_resolved_scope?(%Folder{parent_uuid: parent_uuid}, resolved_parents),
    do: parent_uuid in resolved_parents

  # One query per {kind, key_type} group present among the candidates — not
  # a query per folder — and only the columns an orphan report needs (R9).
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
    |> select([r], struct(r, [:uuid, :number, :status, :deleted_at]))
    |> repo().all()
    |> Map.new(&{{kind, {:uuid, &1.uuid}}, &1})
  end

  defp load_records(kind, :number, numbers) do
    kind
    |> schema_for()
    |> where([r], r.number in ^numbers)
    |> select([r], struct(r, [:uuid, :number, :status, :deleted_at]))
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
          PhoenixKit.Modules.Storage.File
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

  # Fills `counts: nil` placeholders left by `build_move_action/1` (and the
  # `:relocated` action) with a single batched lookup across every action
  # that carries a `:folder` — the batch's folder counts come from one pair
  # of grouped queries (X1), not one pair per action. Duplicate/hook_error
  # report actions carry no `:folder` key and are left untouched
  # (`counts: nil`, they report, never move).
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
