defmodule PhoenixKitWarehouse.InternalOrders do
  @moduledoc """
  Context for managing internal orders (warehouse demand documents).

  Internal orders bridge sub-order material sheets and supplier orders.
  They do NOT affect stock — posting only flips status and sets timestamps.

  ## One draft per source

  `replace_draft_for_source/3` creates a draft and sends the live one-source
  drafts of the same source to the trash (soft delete, restorable with
  `restore_internal_order/3`). It never trashes a posted document, a combined
  one (several sources) or one of another source. `create/3` is unchanged: a
  host opts in by calling the replacing function.

  Moves to the trash and back are logged as `warehouse.internal_order.trashed`
  and `warehouse.internal_order.restored` activities, written after the
  transaction has committed and subject to the `:inventory_activity_logging`
  switch like every other entry of `PhoenixKitWarehouse.ActivityLog`.
  """

  import Ecto.Query

  alias PhoenixKitWarehouse.ActivityLog
  alias PhoenixKitWarehouse.CommittedQuantities
  alias PhoenixKitWarehouse.DraftTrash
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.SourceKinds
  alias PhoenixKitWarehouse.StockLedger

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Lists non-deleted internal orders ordered by number descending (newest first).

  `opts`:
    * `:trashed` (default `false`) - `true` lists the trashed orders instead
      (any status, same order), the content of the trash view.
  """
  def list_internal_orders(opts \\ []) do
    InternalOrder
    |> DraftTrash.scope(Keyword.get(opts, :trashed, false))
    |> order_by([o], desc: o.number)
    |> repo().all()
  end

  @doc "Counts the trashed internal orders (any status)."
  @spec count_trashed_internal_orders() :: non_neg_integer()
  def count_trashed_internal_orders, do: DraftTrash.count_trashed(InternalOrder)

  @doc """
  Lists non-deleted posted internal orders ordered by number descending.
  Used for goods issue source picker — filters in SQL so only relevant rows
  are loaded.
  """
  def list_posted_internal_orders do
    InternalOrder
    |> where([o], is_nil(o.deleted_at) and o.status == "posted")
    |> order_by([o], desc: o.number)
    |> repo().all()
  end

  @doc """
  Lists the live (not trashed) internal orders of any status that reference
  the source `{type, uuid}`, newest first by `inserted_at` (document numbers
  are not chronological). Combined documents that merely include the source
  are listed too; tell them apart with `multi_source?/1`.
  """
  @spec list_for_source(String.t(), String.t()) :: [InternalOrder.t()]
  def list_for_source(type, uuid) when is_binary(type) and is_binary(uuid) do
    InternalOrder
    |> where([o], is_nil(o.deleted_at))
    |> where([o], fragment("? @> ?::jsonb", o.source_refs, ^source_ref_json(type, uuid)))
    |> order_by([o], desc: o.inserted_at, desc: o.uuid)
    |> repo().all()
  end

  @doc """
  True when the order references more than one distinct source `{type, uuid}`
  (a combined document, e.g. one imported from several sub-orders). The same
  source repeated, or carrying an imported `"lines"` key, is still one source.
  """
  @spec multi_source?(InternalOrder.t()) :: boolean()
  def multi_source?(%InternalOrder{source_refs: refs}) do
    (refs || [])
    |> Enum.uniq_by(&{&1["type"], &1["uuid"]})
    |> length()
    |> Kernel.>(1)
  end

  @doc "Returns the internal order or raises."
  def get_internal_order!(uuid), do: repo().get!(InternalOrder, uuid)

  @doc "Returns `{:ok, order}` or `{:error, :not_found}`."
  def get_internal_order(uuid) do
    case repo().get(InternalOrder, uuid) do
      nil -> {:error, :not_found}
      order -> {:ok, order}
    end
  end

  # ---------------------------------------------------------------------------
  # Draft CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new draft internal order.

  `location_uuid` defaults to the configured default warehouse when not given.
  `created_by_uuid` is set programmatically — not via cast.
  """
  def create_internal_order(attrs) do
    location_uuid =
      Map.get(attrs, :location_uuid) || Map.get(attrs, "location_uuid") ||
        StockLedger.default_location_uuid()

    attrs = Map.put(attrs, :location_uuid, location_uuid)
    created_by_uuid = Map.get(attrs, :created_by_uuid) || Map.get(attrs, "created_by_uuid")

    %InternalOrder{}
    |> InternalOrder.changeset(attrs)
    |> Ecto.Changeset.put_change(:created_by_uuid, created_by_uuid)
    |> repo().insert()
  end

  @doc """
  Generic entry point for creating a draft internal order from arbitrary
  lines plus a single (optional) source ref — no domain knowledge of
  "material sheets" or any other host concept required. A host app (e.g.
  Andi's sub-order Show page, per the design doc's "one piece of business
  logic that stays in Andi") builds its own `lines` from whatever concept
  it has, builds a `%{"type" => kind, "uuid" => uuid}` source ref itself,
  and calls this function — replacing the removed `create_from_material_sheet/3`.

  `opts`:
    * `:created_by_uuid` — set programmatically, not via cast.
    * `:location_uuid` — defaults to `StockLedger.default_location_uuid/0`.
  """
  @spec create([map()], map() | nil, keyword()) ::
          {:ok, InternalOrder.t()} | {:error, Ecto.Changeset.t()}
  def create(lines, source_ref, opts \\ []) when is_list(lines) do
    location_uuid = Keyword.get(opts, :location_uuid) || StockLedger.default_location_uuid()
    created_by_uuid = Keyword.get(opts, :created_by_uuid)
    source_refs = if source_ref, do: [source_ref], else: []

    create_internal_order(%{
      location_uuid: location_uuid,
      lines: lines,
      source_refs: source_refs,
      created_by_uuid: created_by_uuid
    })
  end

  @doc """
  Creates a draft like `create/3` and sends the previous drafts of the same
  source to the trash, in one transaction. Returns
  `{:ok, %{order: new_order, superseded: [trashed_orders]}}`.

  `source_ref` is `%{"type" => type, "uuid" => uuid}` (or `nil`, which behaves
  exactly like `create/3` with `superseded: []`). `opts` are those of
  `create/3`; `:created_by_uuid` is also the actor recorded as the one who
  trashed the old drafts.

  Only live drafts whose every source ref is this source are trashed. Posted
  documents, combined drafts (more than one source) and drafts of other
  sources, or of another type with the same uuid, are never touched. Calls for
  the same source are serialised by an advisory lock, so two clicks cannot each
  miss the other's draft.

  Call it outside a transaction of the same repo, otherwise the activity
  entries are written inside the caller's transaction instead of after the
  commit.
  """
  @spec replace_draft_for_source([map()], map() | nil, keyword()) ::
          {:ok, %{order: InternalOrder.t(), superseded: [InternalOrder.t()]}}
          | {:error, term()}
  def replace_draft_for_source(lines, source_ref, opts \\ [])

  def replace_draft_for_source(lines, nil, opts) when is_list(lines) do
    with {:ok, order} <- create(lines, nil, opts), do: {:ok, %{order: order, superseded: []}}
  end

  def replace_draft_for_source(lines, %{"type" => type, "uuid" => uuid} = source_ref, opts)
      when is_list(lines) and is_binary(type) and is_binary(uuid) do
    actor_uuid = Keyword.get(opts, :created_by_uuid)

    result =
      repo().transaction(fn ->
        lock_source!(type, uuid)

        case create(lines, source_ref, opts) do
          {:ok, order} ->
            superseded =
              order.uuid
              |> live_drafts_of_source(type, uuid)
              |> only_source(type, uuid)
              |> trash_drafts(actor_uuid)

            %{order: order, superseded: superseded}

          {:error, reason} ->
            repo().rollback(reason)
        end
      end)

    with {:ok, %{order: order, superseded: superseded}} = ok <- result do
      log_trashed(superseded, actor_uuid, "superseded", order.uuid)
      ok
    end
  end

  def replace_draft_for_source(lines, _source_ref, _opts) when is_list(lines),
    do: {:error, :invalid_source_ref}

  @doc """
  Updates a draft internal order. Returns `{:error, :not_draft}` when not in
  draft status, `{:error, :deleted}` when it is in the trash.

  Locks the row FOR UPDATE and re-checks status == "draft" in the DB (not
  just the in-memory struct) so a stale tab cannot overwrite an order that
  was posted concurrently by another tab/user.
  """
  def update_draft(%InternalOrder{uuid: uuid}, attrs) do
    multi =
      uuid
      |> lock_status_step("draft", :not_draft)
      |> Ecto.Multi.update(:update, fn %{lock_status: locked} ->
        InternalOrder.changeset(locked, attrs)
      end)

    case repo().transaction(multi) do
      {:ok, %{update: updated}} -> {:ok, updated}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Manually attaches a traceability reference to an internal order.

  `type` must be a kind registered via `PhoenixKitWarehouse.SourceKinds`.
  Pure metadata — does not touch `lines` and is not gated to draft status.
  A duplicate `{type, uuid}` pair is a no-op. Returns `{:error, :deleted}` for
  a document in the trash.
  """
  def add_source_ref(%InternalOrder{} = order, type, uuid) do
    if registered_kind?(type) do
      new_ref = %{"type" => type, "uuid" => uuid}

      refs =
        ((order.source_refs || []) ++ [new_ref])
        |> Enum.uniq_by(&{&1["type"], &1["uuid"]})

      update_source_refs(order, refs)
    else
      {:error, :invalid_ref_type}
    end
  end

  defp registered_kind?(type), do: type in Enum.map(SourceKinds.list_kinds(), & &1.kind)

  @doc """
  Detaches a traceability reference from an internal order. No-op when the
  `{type, uuid}` pair isn't present. Returns `{:error, :deleted}` for a
  document in the trash.
  """
  def remove_source_ref(%InternalOrder{} = order, type, uuid) do
    refs = Enum.reject(order.source_refs || [], &(&1["type"] == type and &1["uuid"] == uuid))

    update_source_refs(order, refs)
  end

  # The trash is read from the row (locked), not from the struct, which may be
  # a tab behind.
  defp update_source_refs(order, refs) do
    order
    |> InternalOrder.changeset(%{source_refs: refs})
    |> then(&DraftTrash.update_unless_trashed(InternalOrder, &1))
  end

  # ---------------------------------------------------------------------------
  # Posting
  # ---------------------------------------------------------------------------

  @doc """
  Posts an internal order in an `Ecto.Multi` transaction.

  - Locks the row FOR UPDATE and re-checks status == "draft" (prevents
    double-posting of the same draft).
  - Deduplicates lines by item_uuid.
  - Flips status → "posted", sets posted_at and performed_by_uuid.
  - Does NOT write any stock rows.

  Returns `{:error, :not_draft}` for non-draft orders and `{:error, :deleted}`
  for one in the trash.
  """
  def post_internal_order(%InternalOrder{status: status}, _performed_by_uuid)
      when status != "draft" do
    {:error, :not_draft}
  end

  def post_internal_order(%InternalOrder{} = order, performed_by_uuid) do
    multi =
      order.uuid
      |> lock_status_step("draft", :not_draft)
      |> Ecto.Multi.run(:order, fn repo, %{lock_status: locked} ->
        lines = Enum.uniq_by(locked.lines, & &1["item_uuid"])

        %{locked | lines: lines}
        |> InternalOrder.post_changeset(performed_by_uuid)
        |> repo.update()
      end)

    case repo().transaction(multi) do
      {:ok, %{order: posted}} -> {:ok, posted}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Soft delete
  # ---------------------------------------------------------------------------

  @doc """
  Soft-deletes a draft internal order (sends it to the trash).

  Locks the row and moves it only while it is still a live draft in the
  database, so a draft posted in another tab is not trashed from a stale
  struct. Returns `{:ok, order}`, `{:error, :not_draft}` for posted documents,
  `{:error, :deleted}` when it is already in the trash and
  `{:error, :not_found}` for a row that no longer exists.
  """
  def soft_delete_internal_order(%InternalOrder{status: "draft", uuid: uuid}, actor_uuid) do
    result =
      repo().transaction(fn ->
        case lock_rows([uuid]) do
          [] ->
            repo().rollback(:not_found)

          [%InternalOrder{deleted_at: %DateTime{}}] ->
            repo().rollback(:deleted)

          [%InternalOrder{status: status}] when status != "draft" ->
            repo().rollback(:not_draft)

          [_draft] ->
            case trash_ids([uuid], actor_uuid) do
              [trashed] -> trashed
              [] -> repo().rollback(:not_draft)
            end
        end
      end)

    with {:ok, trashed} <- result do
      log_trashed([trashed], actor_uuid, "manual", nil)
      {:ok, trashed}
    end
  end

  def soft_delete_internal_order(%InternalOrder{}, _actor_uuid), do: {:error, :not_draft}

  @doc """
  Brings a trashed draft internal order back.

  Returns `{:ok, %{order: restored, superseded: [trashed_orders]}}`,
  `{:error, :not_deleted}` for a live one, `{:error, :not_draft}` for a trashed
  posted document (legacy; it stays in the trash) or `{:error, :not_found}`.

  `opts`:
    * `:swap` (default `false`) - when the restored draft has exactly one
      source, the live one-source drafts of that source go to the trash in the
      same transaction (same rules and lock as `replace_draft_for_source/3`), so
      "one draft per source" holds after the restore. A combined draft, or one
      without a source, is restored without a swap whatever this is.

  Call it outside a transaction of the same repo, otherwise the activity
  entries are written inside the caller's transaction instead of after the
  commit.
  """
  @spec restore_internal_order(InternalOrder.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, %{order: InternalOrder.t(), superseded: [InternalOrder.t()]}}
          | {:error, :not_deleted | :not_draft | :not_found}
  def restore_internal_order(%InternalOrder{uuid: uuid}, actor_uuid, opts \\ []) do
    swap? = Keyword.get(opts, :swap, false) == true

    result =
      repo().transaction(fn ->
        with %InternalOrder{} = peek <- repo().get(InternalOrder, uuid),
             :ok <- trashed_draft(peek),
             source = if(swap?, do: single_source(peek)),
             :ok <- lock_swap_source(source),
             [%InternalOrder{} = locked] <- lock_rows([uuid]),
             :ok <- trashed_draft(locked) do
          # Only swap under the lock that was taken: the row could have got
          # another source between the first read and its own lock.
          source = if single_source(locked) == source, do: source
          superseded = swap_out(source, uuid, actor_uuid)

          case restore_row(uuid) do
            %InternalOrder{} = restored -> %{order: restored, superseded: superseded}
            nil -> repo().rollback(:not_deleted)
          end
        else
          nil -> repo().rollback(:not_found)
          [] -> repo().rollback(:not_found)
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    with {:ok, %{order: restored, superseded: superseded}} = ok <- result do
      ActivityLog.log_internal_order_restored(restored, actor_uuid: actor_uuid)
      log_trashed(superseded, actor_uuid, "restore_swap", restored.uuid)
      ok
    end
  end

  defp trashed_draft(%InternalOrder{deleted_at: nil}), do: {:error, :not_deleted}
  defp trashed_draft(%InternalOrder{status: "draft"}), do: :ok
  defp trashed_draft(%InternalOrder{}), do: {:error, :not_draft}

  defp lock_swap_source(nil), do: :ok

  defp lock_swap_source({type, uuid}) do
    lock_source!(type, uuid)
    :ok
  end

  defp swap_out(nil, _own_uuid, _actor_uuid), do: []

  defp swap_out({type, uuid}, own_uuid, actor_uuid) do
    own_uuid
    |> live_drafts_of_source(type, uuid)
    |> only_source(type, uuid)
    |> trash_drafts(actor_uuid)
  end

  defp restore_row(uuid), do: DraftTrash.restore_row(InternalOrder, uuid)

  # ---------------------------------------------------------------------------
  # Correction (note-only on posted)
  # ---------------------------------------------------------------------------

  @doc """
  Corrects the note of an internal order without changing status.
  Works on documents in any status.
  """
  def correct_internal_order(%InternalOrder{} = order, attrs) do
    order
    |> InternalOrder.correction_changeset(attrs)
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Import from source orders / sub-orders
  # ---------------------------------------------------------------------------

  @doc """
  Returns import candidates from every registered `PhoenixKitWarehouse.SourceKinds`
  kind, merged, as `%{kind:, label_prefix:, uuid:, label:, extra:}` maps
  (the exact shape `SourceKinds.search_candidates/1` returns). Returns `[]`
  when no `source_kinds` are configured — this is what makes the module
  usable standalone, with no host "order" concept at all.

  `query` (optional) is forwarded to every registered kind's own `search`
  callback — filtering is each kind's own responsibility, not this
  function's, since only the host knows how to match against its own data
  (order number, client name, etc).
  """
  def list_import_candidates(query \\ nil) do
    SourceKinds.search_candidates(query || "")
  end

  @doc """
  Imports material lines from a list of source refs into an internal order.

  `selected_refs` is a list of `%{"type" => "order" | "sub_order", "uuid" => uuid}`.
  For each source, builds lines via the registered `SourceKinds.build_lines/3`
  callback. Lines are merged into the order's current lines, summing
  required_quantity by item_uuid. New source refs are appended to source_refs
  (deduped). Saves via update_draft. Returns {:ok, order} or {:error, reason}.
  Draft-only.
  """
  def import_from_sources(%InternalOrder{status: "draft"} = order, selected_refs, actor_uuid)
      when is_list(selected_refs) do
    source_uuids = Enum.map(selected_refs, & &1["uuid"])

    committed =
      CommittedQuantities.compute(
        InternalOrder,
        Enum.map(SourceKinds.list_kinds(), & &1.kind),
        source_uuids,
        "required_quantity"
      )

    ref_line_pairs =
      Enum.map(selected_refs, fn ref ->
        raw_lines = lines_for_ref(ref, actor_uuid)
        source_committed = Map.get(committed, ref["uuid"], %{})

        clamped_lines =
          Enum.map(raw_lines, fn line ->
            required = parse_decimal(line["required_quantity"])
            already = Map.get(source_committed, line["item_uuid"], Decimal.new(0))
            remaining = Decimal.max(Decimal.new(0), Decimal.sub(required, already))
            Map.put(line, "required_quantity", StockLedger.format_quantity(remaining))
          end)

        {ref, clamped_lines}
      end)

    incoming_lines = Enum.flat_map(ref_line_pairs, fn {_ref, lines} -> lines end)

    existing = order.lines

    merged =
      Enum.reduce(incoming_lines, existing, fn new_line, acc ->
        item_uuid = new_line["item_uuid"]

        case Enum.find_index(acc, &(&1["item_uuid"] == item_uuid)) do
          nil ->
            acc ++ [new_line]

          idx ->
            List.update_at(acc, idx, fn existing_line ->
              old_qty = parse_decimal(existing_line["required_quantity"])
              new_qty = parse_decimal(new_line["required_quantity"])
              summed = Decimal.add(old_qty, new_qty)
              Map.put(existing_line, "required_quantity", StockLedger.format_quantity(summed))
            end)
        end
      end)

    updated_refs =
      Enum.reduce(ref_line_pairs, order.source_refs || [], fn {ref, lines}, acc_refs ->
        lines_map =
          Map.new(lines, fn line ->
            {line["item_uuid"], parse_decimal(line["required_quantity"])}
          end)

        CommittedQuantities.merge_ref(acc_refs, ref["type"], ref["uuid"], lines_map)
      end)

    update_draft(order, %{lines: merged, source_refs: updated_refs})
  end

  def import_from_sources(%InternalOrder{}, _refs, _actor_uuid), do: {:error, :not_draft}

  defp lines_for_ref(%{"type" => kind, "uuid" => uuid}, actor_uuid) do
    case SourceKinds.build_lines(kind, uuid, actor_uuid) do
      {:ok, lines} -> lines
      :error -> []
      {:error, :unsupported_kind} -> []
    end
  end

  defp lines_for_ref(_ref, _actor_uuid), do: []

  # Delegates to the shared, comma-aware coercion (StockLedger.to_decimal/1) so
  # "1,5" (et/ru decimals) parses to 1.5 instead of silently truncating to 1
  # (Decimal.parse/1 partially matches at the comma).
  defp parse_decimal(value), do: StockLedger.to_decimal(value)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Locks the row FOR UPDATE and asserts it is still a live row in
  # `expected_status`. A miss is explained by a second read: a trashed row
  # answers `:deleted`, anything else the caller's `error`.
  defp lock_status_step(uuid, expected_status, error) do
    Ecto.Multi.run(Ecto.Multi.new(), :lock_status, fn repo, _changes ->
      query =
        from(o in InternalOrder,
          where: o.uuid == ^uuid and o.status == ^expected_status and is_nil(o.deleted_at),
          lock: "FOR UPDATE"
        )

      case repo.one(query) do
        nil -> {:error, miss_reason(repo, uuid, error)}
        %InternalOrder{} = locked -> {:ok, locked}
      end
    end)
  end

  defp miss_reason(repo, uuid, error) do
    case repo.get(InternalOrder, uuid) do
      %InternalOrder{deleted_at: %DateTime{}} -> :deleted
      _ -> error
    end
  end

  # ---------------------------------------------------------------------------
  # One draft per source: locking and the move to the trash
  # ---------------------------------------------------------------------------

  # Serialises everything that changes which drafts of one source are live.
  defp lock_source!(type, uuid),
    do: DraftTrash.advisory_lock!("phoenix_kit_warehouse:io_source:#{type}:#{uuid}")

  defp source_ref_json(type, uuid), do: [%{"type" => type, "uuid" => uuid}]

  defp live_drafts_of_source_query(type, uuid) do
    from(o in InternalOrder,
      where: o.status == "draft" and is_nil(o.deleted_at),
      where: fragment("? @> ?::jsonb", o.source_refs, ^source_ref_json(type, uuid))
    )
  end

  # The live drafts of the source, locked row by row in uuid order (one order
  # in every operation, so two of them cannot wait for each other), except the
  # document the caller has just made.
  defp live_drafts_of_source(own_uuid, type, uuid) do
    type
    |> live_drafts_of_source_query(uuid)
    |> where([o], o.uuid != ^own_uuid)
    |> lock_query()
    |> repo().all()
  end

  defp lock_query(query), do: DraftTrash.lock_query(query)

  defp lock_rows(uuids), do: DraftTrash.lock_rows(InternalOrder, uuids)

  # Documents whose every source ref is exactly this source. A combined draft,
  # or one with a ref of an unreadable shape, is kept: a wrongly trashed
  # combined draft would destroy the demand of its other sources.
  defp only_source(orders, type, uuid) do
    Enum.filter(orders, &(single_source(&1) == {type, uuid}))
  end

  defp single_source(%InternalOrder{source_refs: refs}) do
    refs
    |> List.wrap()
    |> Enum.map(&source_key/1)
    |> Enum.uniq()
    |> case do
      [{type, uuid} = key] when is_binary(type) and is_binary(uuid) -> key
      _ -> nil
    end
  end

  defp source_key(%{"type" => type, "uuid" => uuid}), do: {type, uuid}
  defp source_key(_other), do: nil

  # Moves the given (already locked) rows to the trash; see `DraftTrash`.
  # Nothing here writes activity: the caller does that after the commit.
  defp trash_drafts(rows, actor_uuid), do: rows |> Enum.map(& &1.uuid) |> trash_ids(actor_uuid)

  defp trash_ids(ids, actor_uuid), do: DraftTrash.trash_ids(InternalOrder, ids, actor_uuid)

  defp log_trashed(orders, actor_uuid, reason, superseded_by_uuid) do
    Enum.each(orders, fn order ->
      ActivityLog.log_internal_order_trashed(order,
        actor_uuid: actor_uuid,
        reason: reason,
        superseded_by_uuid: superseded_by_uuid
      )
    end)
  end
end
