defmodule PhoenixKitWarehouse.MediaReorganizer do
  @moduledoc """
  Warehouse's media-reorganizer plan source.

  Implements the contract of core's `PhoenixKit.Modules.Storage.Reorganizer.Source`
  (core ≥ 2.24.0) without declaring `@behaviour`: the `phoenix_kit` pin
  floor (`~> 2.0`) predates that module, where `@behaviour` would warn. The
  engine only calls `plan/2` and validates the plain maps it returns, so
  nothing else is needed; see `PhoenixKitWarehouse.media_reorganizer/0` for
  the registration side. Once the floor reaches 2.24.0 the only follow-up
  is adding `@behaviour`/`@impl`.

  Covers all six warehouse documents — `GoodsIssue`, `GoodsReceipt`,
  `InventoryDocument`, `SupplierOrder`, `InternalOrder`, `Transfer` — plus
  orphaned legacy document folders whose record is gone or soft-deleted
  (reported, never moved/trashed — see `orphan_actions/3`).

  Contract (design §9-§12 of `2026-09-15-media-reorganizer-design.md`):

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
      `kind: :hook_nil` report instead. This applies on BOTH resolution
      routes — a document found by its live pointer, and one with no valid
      pointer whose legacy-named folder is found live under some other real
      parent while the hook answers root (U1): that folder is adopted as
      the document's current folder exactly the same way.
    * **A *candidate* is a LIVE DOCUMENT with a folder (F4, strict)** — its
      own valid live pointer, or a live folder anywhere named after its own
      legacy pattern (`<prefix>-<number-or-uuid>`, resolved without calling
      any hook — one SQL-`LIKE`-filtered query for the whole plan). A
      residual legacy-named folder with no live document behind it does
      NOT make its kind a candidate: the `:storage_parent_folder` hook
      (2-arity, `resource`/`actor_uuid` — no record subject) is resolved
      **once per candidate kind**, never once per record and never for a
      kind with zero live documents — even one with a residual folder.
      Cost: an orphan sitting under that kind's would-be resolved parent is
      invisible to this scan (that parent is only ever known via a hook
      call this module skips when the kind has nothing live) — it is only
      found once the kind has at least one live document again.
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
  (`kind: :duplicate | :relocated | :hook_error | :hook_nil`) for anything
  that cannot be safely moved, plus a `:report` (`kind: :orphan`) per
  legacy-named folder whose document is gone or soft-deleted.

  `opts` is accepted for signature parity with the engine's `Source.plan/2`
  contract; this module has nothing to key off `opts[:pending_days]` — it
  stages no pending folders.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, _opts \\ []) do
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

        {:invalid, reason} ->
          {actions, parents, claims} =
            build_resource_plan(actor_uuid, prelim, legacy_candidates, pointer_claims, false)

          {[invalid_hook_action(reason) | actions], parents, claims}

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
  # the owner why nothing moved. U7/V3: anything configured that is not
  # even a `{mod, fun}` shape (garbage config) is the SAME failure — never
  # silently treated as "no hook configured" either.
  defp hook_status do
    case Application.get_env(:phoenix_kit_warehouse, :storage_parent_folder) do
      nil ->
        :none

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        if callable?(mod, fun), do: :ok, else: {:invalid, {:not_callable, mod, fun}}

      other ->
        {:invalid, {:bad_config, other}}
    end
  end

  defp callable?(mod, fun), do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2)

  defp invalid_hook_action(reason) do
    %{
      source: @source,
      kind: :hook_error,
      op: :report,
      label: "storage_parent_folder hook",
      counts: nil,
      reason: invalid_hook_reason(reason)
    }
  end

  defp invalid_hook_reason({:not_callable, mod, fun}),
    do: "configured parent hook {#{inspect(mod)}, #{inspect(fun)}} is not callable"

  defp invalid_hook_reason({:bad_config, other}),
    do:
      "configured parent hook #{inspect(other)} is not a {module, function} tuple — " <>
        "invalid config, not callable"

  # R9: only the columns a plan needs — never a full row (four of the six
  # schemas carry a `lines` jsonb column that can be large).
  defp light_fields(kind) when kind in @pointer_kinds,
    do: [:uuid, :number, :storage_folder_uuid, :inserted_at]

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

  # F4 (strict): a candidate is a LIVE DOCUMENT with a folder — its own
  # valid live pointer, or a live folder anywhere named after its own
  # legacy pattern. A residual legacy-named folder with no live document
  # behind it does NOT make its kind a candidate: the parent hook is never
  # called for that kind at all (see the moduledoc's "Orphaned legacy
  # folders" section for the resulting cost — an orphan under such a
  # container's would-be resolved parent is invisible to this scan, since
  # that parent is only ever known via a hook call this module now skips
  # for a kind with nothing live to move). Only kinds with at least one
  # such candidate go on to have the host's parent hook resolved — once
  # per kind, never once per record (X12).
  defp build_resource_plan(actor_uuid, prelim, legacy_candidates, pointer_claims, hook_on?) do
    by_pointer = preload_by_uuid(Enum.map(prelim, & &1.pointer))
    by_name = group_by_name(legacy_candidates)

    candidates =
      Enum.filter(prelim, fn p ->
        (p.pointer && Map.has_key?(by_pointer, p.pointer)) ||
          Map.has_key?(by_name, p.legacy_name)
      end)

    candidate_kinds = candidates |> Enum.map(& &1.kind) |> MapSet.new()

    # E1: without a configured hook the desired parent is root for every
    # kind (D1/§4) — never call the hook (there is none), never a
    # hook-error candidate.
    {ok_parents, hook_error_kinds} =
      if hook_on? do
        resolve_parents(candidate_kinds, actor_uuid)
      else
        {Map.new(candidate_kinds, &{&1, nil}), MapSet.new()}
      end

    {ok_candidates, failed_candidates} =
      Enum.split_with(candidates, &(not MapSet.member?(hook_error_kinds, &1.kind)))

    desired =
      Enum.map(ok_candidates, &Map.put(&1, :parent_uuid, Map.fetch!(ok_parents, &1.kind)))

    entries =
      desired
      |> Enum.map(&resolve_entry(&1, by_pointer, by_name))
      |> apply_nil_root_guard(hook_on?)

    hook_nil_entries = Enum.filter(entries, & &1.hook_nil)

    # X11: a legacy name live at both root and under the resolved parent is
    # unresolvable — one `:duplicate` report, never a move for that
    # document; every OTHER live match for the same name is still a stray
    # twin (handled below, alongside `with_folder`/`without_folder`).
    {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
    {with_folder, without_folder} = Enum.split_with(normal, & &1.folder)

    {shared, unique} = split_shared(with_folder)

    # U2: convergence is computed AFTER the no-op filter, among real movers
    # only — a document already sitting at its target (nothing to move,
    # F6) is excluded before grouping, so it can never drag a genuine mover
    # heading to the very same folder into a false `:duplicate` (that mover
    # still gets its own `:move`; if it lands on an in-place noop's folder,
    # `on_conflict: :suffix` resolves the physical collision at apply time,
    # same as any other stray twin). Only makes sense with a working hook —
    # without one, every candidate's desired parent defaults to root
    # regardless of its real current parent, and a coincidental name match
    # at that default would be a false positive (P6).
    {movers, static} = Enum.split_with(unique, &real_move?/1)

    {converging, solo_movers} =
      if hook_on?, do: split_converging(movers), else: {[], movers}

    solo = Enum.sort_by(solo_movers ++ static, & &1.order_index)

    # E1: `:move` (and any pointer back-fill it carries) is only ever
    # planned when a hook is configured — a host without one is untouched,
    # even though the duplicate/relocated reports above still stand.
    move_actions =
      if hook_on?, do: solo |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1), else: []

    dup_actions = Enum.map(ambiguous, &build_ambiguous_duplicate_action/1)
    shared_actions = Enum.map(shared, &build_shared_duplicate_action/1)
    converging_actions = Enum.map(converging, &build_converging_duplicate_action/1)

    hook_error_actions = hook_error_action(failed_candidates)
    hook_nil_actions = hook_nil_action(hook_nil_entries)

    claimed = claimed_folder_uuids(solo, ambiguous, shared, converging)
    all_claimed = MapSet.union(claimed, pointer_claims)

    # T5: every live legacy-named copy other than a document's own adopted
    # current folder gets its own `:relocated` report — all of them, not
    # only the first — except a copy that is itself another document's
    # claimed (adopted) folder, which is never also reported `:relocated`.
    # U9: includes `ambiguous` too — a THIRD (or further) live copy beyond
    # the pair the `:duplicate` report already names must still surface
    # here, not be dropped.
    stray_actions =
      (with_folder ++ without_folder ++ ambiguous)
      |> Enum.flat_map(&stray_pairs(&1, all_claimed))
      |> stray_relocated_actions()

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
  # U6: a bad-but-non-raising return (garbage UUID, unexpected shape) is
  # logged too — not just silently counted — with the same `{mod, fun}` +
  # kind identifying detail as the raise/exit paths below.
  defp guarded_hook_call(mod, fun, kind, actor_uuid) do
    case apply(mod, fun, [kind, actor_uuid]) do
      {:ok, uuid} when is_binary(uuid) ->
        case valid_uuid(uuid) do
          nil ->
            log_bad_hook_return(mod, fun, kind, {:ok, uuid})
            :error

          cast ->
            {:ok, cast}
        end

      {:ok, nil} ->
        {:ok, nil}

      nil ->
        {:ok, nil}

      other ->
        log_bad_hook_return(mod, fun, kind, other)
        :error
    end
  rescue
    error ->
      Logger.warning(
        "storage_parent_folder hook {#{inspect(mod)}, #{inspect(fun)}} raised for kind " <>
          "#{inspect(kind)}: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  catch
    catch_kind, reason ->
      Logger.warning(
        "storage_parent_folder hook {#{inspect(mod)}, #{inspect(fun)}} #{catch_kind} for " <>
          "kind #{inspect(kind)}: #{inspect(reason)}"
      )

      :error
  end

  defp log_bad_hook_return(mod, fun, kind, value) do
    Logger.warning(
      "storage_parent_folder hook {#{inspect(mod)}, #{inspect(fun)}} for kind " <>
        "#{inspect(kind)} returned an unexpected value (neither {:ok, uuid} nor nil): " <>
        inspect(value)
    )
  end

  # U8: `:hook_error`/`:hook_nil` reports list up to this many record
  # labels before collapsing the rest into a single "… and N more" tail —
  # enough for an owner to know where to look without the report itself
  # becoming an unbounded wall of text on a large failure.
  @max_listed_labels 10

  defp label_list(entries) do
    labels = Enum.map(entries, & &1.legacy_name)
    count = length(labels)

    if count > @max_listed_labels do
      shown = Enum.take(labels, @max_listed_labels) |> Enum.join(", ")
      "#{shown}, … and #{count - @max_listed_labels} more"
    else
      Enum.join(labels, ", ")
    end
  end

  defp hook_error_action([]), do: []

  defp hook_error_action(failed_candidates) do
    [
      %{
        source: @source,
        kind: :hook_error,
        op: :report,
        label: "storage_parent_folder hook",
        counts: nil,
        reason: hook_error_reason(failed_candidates)
      }
    ]
  end

  # F4 removed the orphan-scan-only failure case this used to special-case
  # (`doc_count == 0`): a kind only ever reaches `resolve_parents/2` when it
  # has at least one live-document candidate, so a failed kind always has
  # at least one failed candidate document too.
  defp hook_error_reason(failed_candidates) do
    "#{length(failed_candidates)} document(s) skipped: the configured parent hook raised, " <>
      "exited, or returned neither {:ok, uuid} nor nil (#{label_list(failed_candidates)})"
  end

  # F1/U1: an explicit `nil`/`{:ok, nil}` answer from the parent hook never
  # pulls a folder that currently lives under a real parent out to root —
  # only a pointer back-fill (if any) is kept, and the parent/name stay
  # exactly as they are (no rename either, since the desired name isn't
  # being applied). Named/pointer resolution above already guarantees
  # `entry.folder` is the document's actual current folder when set, so
  # this covers the pointer-track case directly. Skipped entirely without a
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

  # U1: the name-track equivalent, for a pointer-writing kind only (a
  # pointer-less kind, `internal_order`, keeps reporting every live legacy
  # twin as `:relocated` — it has no pointer to back-fill, so there is
  # nothing for F1 to adopt). Nothing resolved via pointer or name match
  # (`folder: nil`) because the hook answered root and no live copy sits at
  # root either — but exactly ONE live copy sits under some other real
  # parent (`stray_legacy`): that folder IS the document's current folder,
  # adopted (kept name, kept parent), planning only the pointer back-fill
  # and counting into `:hook_nil` — never a move to root. Two or more such
  # copies stay unresolved (same as today's "nothing resolves" case) —
  # adopting one over another arbitrarily would be a guess this module
  # doesn't make.
  defp apply_nil_root_guard(%{folder: nil, parent_uuid: nil, kind: kind} = entry)
       when kind in @pointer_kinds do
    case Enum.filter(entry.stray_legacy, &(not is_nil(&1.parent_uuid))) do
      [folder] ->
        entry
        |> Map.put(:folder, folder)
        |> Map.put(:via, :name)
        |> Map.put(:name, nil)
        |> Map.put(:parent_uuid, folder.parent_uuid)
        |> Map.put(:hook_nil, true)
        |> Map.put(:stray_legacy, Enum.reject(entry.stray_legacy, &(&1.uuid == folder.uuid)))

      _other ->
        Map.put(entry, :hook_nil, false)
    end
  end

  defp apply_nil_root_guard(entry), do: Map.put(entry, :hook_nil, false)

  defp hook_nil_action([]), do: []

  defp hook_nil_action(hook_nil_entries) do
    [
      %{
        source: @source,
        kind: :hook_nil,
        op: :report,
        label: "storage_parent_folder hook",
        counts: nil,
        reason:
          "#{length(hook_nil_entries)} document(s): the parent hook answered root for a " <>
            "folder living under a parent — left in place (#{label_list(hook_nil_entries)})"
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
        # U9: a THIRD (or further) live copy beyond the ambiguous pair is
        # still a stray twin — kept for `:relocated`, never dropped just
        # because the pair itself is unresolvable.
        Map.merge(d, %{
          folder: nil,
          via: nil,
          name: nil,
          ambiguous: {under_parent, at_root},
          stray_legacy: Enum.reject(matches, &(&1 in [under_parent, at_root]))
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
  defp stray_pairs(entry, claimed) do
    entry.stray_legacy
    |> Enum.reject(&MapSet.member?(claimed, &1.uuid))
    |> Enum.map(&{entry, &1})
  end

  defp stray_relocated_actions(pairs) do
    parent_names = load_stray_parent_names(pairs)

    Enum.map(pairs, fn {entry, folder} ->
      build_relocated_action(%{
        legacy_name: entry.legacy_name,
        kind: entry.kind,
        relocated: folder,
        target_parent_uuid: entry.parent_uuid,
        parent_names: parent_names
      })
    end)
  end

  # One query for the whole batch — only parents that are neither root nor
  # the document's own target need a name; those two cases have their own
  # wording in `relocated_reason/4`.
  defp load_stray_parent_names(pairs) do
    uuids =
      pairs
      |> Enum.map(fn {entry, folder} -> other_parent_uuid(folder, entry.parent_uuid) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case uuids do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids)
        |> select([f], {f.uuid, f.name})
        |> repo().all()
        |> Map.new()
    end
  end

  defp other_parent_uuid(%Folder{parent_uuid: nil}, _target_parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, _target_parent_uuid), do: parent_uuid

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
  # needs no pointer back-fill is a no-op — filtered out here before it
  # ever reaches the core engine. A folder resolved via name
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

  # T5/F5: the reason names the copy's ACTUAL place — at the storage root,
  # already under the very parent the document is headed to (where an
  # eventual move will land next to it as a `"name (N)"` suffixed twin), or
  # under a genuine third-party parent, named (Source contract) — instead of a blanket
  # "under a different parent" that reads wrong for all three cases.
  defp build_relocated_action(%{
         legacy_name: legacy_name,
         kind: kind,
         relocated: folder,
         target_parent_uuid: target_parent_uuid,
         parent_names: parent_names
       }) do
    %{
      source: @source,
      kind: :relocated,
      op: :report,
      label: legacy_name,
      folder: folder,
      counts: nil,
      reason: relocated_reason(folder, kind, target_parent_uuid, parent_names)
    }
  end

  defp relocated_reason(%Folder{uuid: uuid, parent_uuid: nil}, kind, _target_parent_uuid, _names) do
    "legacy folder #{uuid} (#{kind}) is live at the storage root — left alone, never adopted"
  end

  defp relocated_reason(%Folder{uuid: uuid, parent_uuid: parent_uuid}, kind, parent_uuid, _names)
       when not is_nil(parent_uuid) do
    "legacy folder #{uuid} (#{kind}) is already live as a twin under the target parent " <>
      "— left alone; an eventual move there will collide, landing as \"name (N)\""
  end

  defp relocated_reason(%Folder{uuid: uuid, parent_uuid: parent_uuid}, kind, _target, names) do
    parent_label = names |> Map.get(parent_uuid, parent_uuid) |> inspect()

    "legacy folder #{uuid} (#{kind}) is live under a different parent, #{parent_label} " <>
      "(#{parent_uuid}) — left alone, never adopted"
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
  # again. A pointer that changed since plan time (e.g. `ensure_for_*`
  # created and cached a fresh folder in between) aborts too — overwriting
  # it would strand whatever was uploaded into that new folder; the next
  # plan run sees the new state. Already pointing at the folder is `:ok`.
  # `set_storage_folder/2` is a narrow
  # single-column changeset + plain `repo().update()` — no Activity log, no
  # PubSub, no full-record validation (D7).
  defp write_pointer(kind, record, folder_uuid) do
    planned_pointer = record.storage_folder_uuid

    case locked_record(kind, record.uuid) do
      nil ->
        {:error, :not_found}

      %{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        {:error, :record_deleted}

      %{storage_folder_uuid: ^folder_uuid} ->
        :ok

      %{storage_folder_uuid: ^planned_pointer} = current ->
        case setter_for(kind).(current, folder_uuid) do
          {:ok, _updated} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _changed ->
        {:error, :pointer_changed}
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
  # name starts with one of the six legacy prefixes — used both to resolve
  # each candidate's current folder (X12) and, filtered down to root/
  # resolved-parent scope, as the orphan candidate set itself. F4 (strict):
  # a kind with a residual folder but zero live documents is NOT a
  # candidate kind (see `build_resource_plan/5`) — its parent hook is never
  # resolved, so an orphan under that kind's would-be parent is not found
  # until the kind has a live document again. Live only (X2).
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
