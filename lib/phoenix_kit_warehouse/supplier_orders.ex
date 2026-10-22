defmodule PhoenixKitWarehouse.SupplierOrders do
  @moduledoc """
  Context for managing supplier orders (purchase orders to a single supplier).

  Supplier orders are generated (semi-automatically) from posted internal orders.
  Posting has NO stock effect — goods receipt will do that.

  ## One draft per (internal order, supplier)

  `generate_from_internal_order/3` and `apply_plan/5` never make a second
  draft for a supplier that already has a live one for the internal order:
  what is still missing is appended to it (`target_lines/2`), and nothing goes
  to the trash - the `supersede_drafts` option is accepted and does nothing.
  Both run under the advisory lock of the internal order, as do
  `import_from_internal_orders/3` and a restore with `swap: true`, which sends
  the live drafts of the restored draft's pair to the trash (soft delete,
  restorable with `restore_supplier_order/3`).

  ## The version of a draft

  The supplier order form writes a draft's lines, refs and note whole, from
  what it read. So that a write from a form opened before generation appended
  to the draft does not wipe what was appended, `update_draft/3`,
  `post_supplier_order/3`, `add_source_ref/4`, `remove_source_ref/4` and
  `import_from_internal_orders/4` take `expected_version:` - the
  `draft_version/1` of the draft the caller saw. Under the row lock it is
  compared with the row's: when it differs, `{:error, :stale}` and nothing is
  written (a missing, trashed or posted document answers that first). Without
  the option they write as before.

  Moves to the trash and back are logged as `warehouse.supplier_order.trashed`
  and `warehouse.supplier_order.restored` activities, written after the
  transaction has committed and subject to the `:inventory_activity_logging`
  switch like every other entry of `PhoenixKitWarehouse.ActivityLog`.
  """

  import Ecto.Query

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.ActivityLog
  alias PhoenixKitWarehouse.CommittedQuantities
  alias PhoenixKitWarehouse.DraftTrash
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.LineExplanation
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKitWarehouse.SupplierOrderPlan

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Lists non-deleted supplier orders ordered by number descending (newest first).

  `opts`:
    * `:trashed` (default `false`) - `true` lists the trashed orders instead
      (any status, same order), the content of the trash view.
  """
  def list_supplier_orders(opts \\ []) do
    SupplierOrder
    |> DraftTrash.scope(Keyword.get(opts, :trashed, false))
    |> order_by([o], desc: o.number)
    |> repo().all()
  end

  @doc "Counts the trashed supplier orders (any status)."
  @spec count_trashed_supplier_orders() :: non_neg_integer()
  def count_trashed_supplier_orders, do: DraftTrash.count_trashed(SupplierOrder)

  @doc """
  Lists, by number, the live drafts with a supplier of the internal order
  alone (`single_source?/2`): the drafts of its (internal order, supplier)
  pairs. It only reads (nothing is locked). Generation does not use it: it
  sends nothing to the trash and finds the draft it appends to under its own
  lock.
  """
  @spec list_replaceable_drafts(Ecto.UUID.t()) :: [SupplierOrder.t()]
  def list_replaceable_drafts(internal_order_uuid) when is_binary(internal_order_uuid) do
    from(o in SupplierOrder,
      where: o.status == "draft" and is_nil(o.deleted_at),
      where: o.internal_order_uuid == ^internal_order_uuid and not is_nil(o.supplier_uuid),
      order_by: [asc: o.number]
    )
    |> repo().all()
    |> only_internal_order(internal_order_uuid)
  end

  @doc """
  Whether `order` is a supplier order of the internal order alone: it names
  it in `internal_order_uuid` and refers to no other document (no refs at all
  counts). Such an order is "the draft of the pair (internal order,
  supplier)" of generation, counts its own lines as ordered for the internal
  order, and is what a restore with a swap may replace.
  """
  @spec single_source?(SupplierOrder.t(), Ecto.UUID.t()) :: boolean()
  def single_source?(
        %SupplierOrder{internal_order_uuid: io_uuid, source_refs: refs},
        io_uuid
      )
      when is_binary(io_uuid) do
    Enum.all?(List.wrap(refs), &match?(%{"type" => "internal_order", "uuid" => ^io_uuid}, &1))
  end

  def single_source?(%SupplierOrder{}, _internal_order_uuid), do: false

  @doc """
  Lists non-deleted POSTED supplier orders ordered by number descending.

  Used as candidates for importing lines into a goods receipt.
  """
  def list_posted_supplier_orders do
    SupplierOrder
    |> where([o], is_nil(o.deleted_at) and o.status == "posted")
    |> order_by([o], desc: o.number)
    |> repo().all()
  end

  @doc "Returns the supplier order or raises."
  def get_supplier_order!(uuid), do: repo().get!(SupplierOrder, uuid)

  @doc "Returns `{:ok, order}` or `{:error, :not_found}`."
  def get_supplier_order(uuid) do
    case repo().get(SupplierOrder, uuid) do
      nil -> {:error, :not_found}
      order -> {:ok, order}
    end
  end

  # ---------------------------------------------------------------------------
  # Draft CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new draft supplier order.

  `location_uuid` defaults to the configured default warehouse when not given.
  `created_by_uuid` is set programmatically — not via cast.
  """
  def create_supplier_order(attrs) do
    location_uuid =
      Map.get(attrs, :location_uuid) || Map.get(attrs, "location_uuid") ||
        StockLedger.default_location_uuid()

    attrs = Map.put(attrs, :location_uuid, location_uuid)
    created_by_uuid = Map.get(attrs, :created_by_uuid) || Map.get(attrs, "created_by_uuid")

    %SupplierOrder{}
    |> SupplierOrder.changeset(attrs)
    |> Ecto.Changeset.put_change(:created_by_uuid, created_by_uuid)
    |> repo().insert()
  end

  @doc """
  The version of a supplier order: a hash of what the form writes and shows -
  `lines`, `source_refs`, `supplier_uuid`, `note`, `status`, `deleted_at`.

  The values go through JSON first, the way the database stores them (a
  `Decimal` becomes its string), and map keys are hashed in order, so the
  struct a write returns and the same row read back have one version. Pass it
  as `expected_version:` to the writes of a draft (see the moduledoc).
  """
  @spec draft_version(SupplierOrder.t()) :: String.t()
  def draft_version(%SupplierOrder{} = order) do
    order
    |> Map.take([:lines, :source_refs, :supplier_uuid, :note, :status, :deleted_at])
    |> Jason.encode!()
    |> Jason.decode!()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # The locked row against the `expected_version:` of the caller, if any.
  defp check_version(%SupplierOrder{} = row, opts) do
    case Keyword.get(opts, :expected_version) do
      nil -> :ok
      version -> if draft_version(row) == version, do: :ok, else: {:error, :stale}
    end
  end

  @doc """
  Updates a draft supplier order. Returns `{:error, :not_draft}` when not in
  draft status, `{:error, :deleted}` when it is in the trash.

  Locks the row FOR UPDATE and re-checks status == "draft" in the DB (not
  just the in-memory struct) so a stale tab cannot overwrite an order that
  was posted concurrently by another tab/user.

  `opts`:
    * `:expected_version` - the `draft_version/1` the caller saw; when the
      row's differs, `{:error, :stale}` and nothing is written (`nil` checks
      nothing).
  """
  @spec update_draft(SupplierOrder.t(), map(), keyword()) ::
          {:ok, SupplierOrder.t()}
          | {:error, :not_draft | :deleted | :stale | Ecto.Changeset.t() | term()}
  def update_draft(%SupplierOrder{uuid: uuid}, attrs, opts \\ []) do
    multi =
      uuid
      |> lock_status_step("draft", :not_draft)
      |> version_step(opts)
      |> Ecto.Multi.update(:update, fn %{lock_status: locked} ->
        SupplierOrder.changeset(locked, attrs)
      end)

    case repo().transaction(multi) do
      {:ok, %{update: updated}} -> {:ok, updated}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Manually attaches a traceability reference (`type` "internal_order") to a
  supplier order.

  Pure metadata — does not touch `lines` and is not gated to draft status.
  A duplicate `{type, uuid}` pair is a no-op. Returns `{:error, :deleted}` for
  a document in the trash; with `expected_version:` (see `update_draft/3`),
  `{:error, :stale}` when the row's version differs.
  """
  @spec add_source_ref(SupplierOrder.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, SupplierOrder.t()}
          | {:error, :deleted | :not_found | :stale | Ecto.Changeset.t()}
  def add_source_ref(%SupplierOrder{} = order, type, uuid, opts \\ [])
      when type in ["internal_order"] do
    new_ref = %{"type" => type, "uuid" => uuid}

    refs =
      ((order.source_refs || []) ++ [new_ref])
      |> Enum.uniq_by(&{&1["type"], &1["uuid"]})

    update_source_refs(order, refs, opts)
  end

  @doc """
  Detaches a traceability reference from a supplier order. No-op when the
  `{type, uuid}` pair isn't present. Returns `{:error, :deleted}` for a
  document in the trash; with `expected_version:` (see `update_draft/3`),
  `{:error, :stale}` when the row's version differs.
  """
  @spec remove_source_ref(SupplierOrder.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, SupplierOrder.t()}
          | {:error, :deleted | :not_found | :stale | Ecto.Changeset.t()}
  def remove_source_ref(%SupplierOrder{} = order, type, uuid, opts \\ []) do
    refs = Enum.reject(order.source_refs || [], &(&1["type"] == type and &1["uuid"] == uuid))

    update_source_refs(order, refs, opts)
  end

  # The trash and the version are read from the row (locked), not from the
  # struct, which may be a tab behind.
  defp update_source_refs(order, refs, opts) do
    order
    |> SupplierOrder.changeset(%{source_refs: refs})
    |> then(
      &DraftTrash.update_unless_trashed(SupplierOrder, &1, fn row -> check_version(row, opts) end)
    )
  end

  # ---------------------------------------------------------------------------
  # Posting
  # ---------------------------------------------------------------------------

  @doc """
  Posts a supplier order in an `Ecto.Multi` transaction.

  - Locks the row FOR UPDATE and re-checks status == "draft" (prevents
    double-posting of the same draft).
  - Deduplicates lines by item_uuid.
  - Flips status → "posted", sets posted_at and performed_by_uuid.
  - Does NOT write any stock rows.

  Returns `{:error, :not_draft}` for non-draft orders and `{:error, :deleted}`
  for one in the trash; with `expected_version:` (see `update_draft/3`),
  `{:error, :stale}` when the row's version differs - nothing is posted.
  """
  @spec post_supplier_order(SupplierOrder.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, SupplierOrder.t()}
          | {:error, :not_draft | :deleted | :stale | Ecto.Changeset.t() | term()}
  def post_supplier_order(order, performed_by_uuid, opts \\ [])

  def post_supplier_order(%SupplierOrder{status: status}, _performed_by_uuid, _opts)
      when status != "draft" do
    {:error, :not_draft}
  end

  def post_supplier_order(%SupplierOrder{} = order, performed_by_uuid, opts) do
    multi =
      order.uuid
      |> lock_status_step("draft", :not_draft)
      |> version_step(opts)
      |> Ecto.Multi.run(:order, fn repo, %{lock_status: locked} ->
        lines = Enum.uniq_by(locked.lines, & &1["item_uuid"])

        %{locked | lines: lines}
        |> SupplierOrder.post_changeset(performed_by_uuid)
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
  Soft-deletes a draft supplier order (sends it to the trash).

  Locks the row and moves it only while it is still a live draft in the
  database, so a draft posted in another tab is not trashed from a stale
  struct. Returns `{:ok, order}`, `{:error, :not_draft}` for posted documents,
  `{:error, :deleted}` when it is already in the trash and
  `{:error, :not_found}` for a row that no longer exists.
  """
  def soft_delete_supplier_order(%SupplierOrder{status: "draft", uuid: uuid}, actor_uuid) do
    result =
      repo().transaction(fn ->
        case lock_rows([uuid]) do
          [] ->
            repo().rollback(:not_found)

          [%SupplierOrder{deleted_at: %DateTime{}}] ->
            repo().rollback(:deleted)

          [%SupplierOrder{status: status}] when status != "draft" ->
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

  def soft_delete_supplier_order(%SupplierOrder{}, _actor_uuid), do: {:error, :not_draft}

  @doc """
  Brings a trashed draft supplier order back.

  Returns `{:ok, %{order: restored, superseded: [trashed_orders]}}`,
  `{:error, :not_deleted}` for a live one, `{:error, :not_draft}` for a trashed
  posted document (legacy; it stays in the trash) or `{:error, :not_found}`.

  `opts`:
    * `:swap` (default `false`) - when the restored draft belongs to one
      (internal order, supplier) pair and refers to no other internal order,
      the live drafts of that pair that refer to no other internal order go to
      the trash in the same transaction (under the advisory lock of the
      internal order that generation takes), so "one draft per pair" holds
      after the restore. A combined draft, or one
      without a supplier or an internal order, is restored without a swap
      whatever this is.

  Call it outside a transaction of the same repo, otherwise the activity
  entries are written inside the caller's transaction instead of after the
  commit.
  """
  @spec restore_supplier_order(SupplierOrder.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, %{order: SupplierOrder.t(), superseded: [SupplierOrder.t()]}}
          | {:error, :not_deleted | :not_draft | :not_found}
  def restore_supplier_order(%SupplierOrder{uuid: uuid}, actor_uuid, opts \\ []) do
    swap? = Keyword.get(opts, :swap, false) == true

    result =
      repo().transaction(fn ->
        with %SupplierOrder{} = peek <- repo().get(SupplierOrder, uuid),
             :ok <- trashed_draft(peek),
             pair = if(swap?, do: single_pair(peek)),
             :ok <- lock_swap_pair(pair),
             [%SupplierOrder{} = locked] <- lock_rows([uuid]),
             :ok <- trashed_draft(locked) do
          # Only swap under the lock that was taken: the row could have got
          # another pair between the first read and its own lock.
          pair = if single_pair(locked) == pair, do: pair
          superseded = swap_out(pair, uuid, actor_uuid)

          case DraftTrash.restore_row(SupplierOrder, uuid) do
            %SupplierOrder{} = restored -> %{order: restored, superseded: superseded}
            nil -> repo().rollback(:not_deleted)
          end
        else
          nil -> repo().rollback(:not_found)
          [] -> repo().rollback(:not_found)
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    with {:ok, %{order: restored, superseded: superseded}} = ok <- result do
      ActivityLog.log_supplier_order_restored(restored, actor_uuid: actor_uuid)
      log_trashed(superseded, actor_uuid, "restore_swap", restored.uuid)
      ok
    end
  end

  defp trashed_draft(%SupplierOrder{deleted_at: nil}), do: {:error, :not_deleted}
  defp trashed_draft(%SupplierOrder{status: "draft"}), do: :ok
  defp trashed_draft(%SupplierOrder{}), do: {:error, :not_draft}

  defp lock_swap_pair(nil), do: :ok

  defp lock_swap_pair({internal_order_uuid, _supplier_uuid}) do
    lock_internal_order!(internal_order_uuid)
    :ok
  end

  defp swap_out(nil, _own_uuid, _actor_uuid), do: []

  defp swap_out({internal_order_uuid, supplier_uuid}, own_uuid, actor_uuid) do
    from(o in SupplierOrder,
      where: o.status == "draft" and is_nil(o.deleted_at) and o.uuid != ^own_uuid,
      where: o.internal_order_uuid == ^internal_order_uuid and o.supplier_uuid == ^supplier_uuid
    )
    |> lock_query()
    |> repo().all()
    |> only_internal_order(internal_order_uuid)
    |> trash_drafts(actor_uuid)
  end

  # ---------------------------------------------------------------------------
  # Correction (note + storage_folder on posted)
  # ---------------------------------------------------------------------------

  @doc """
  Corrects the note and/or storage_folder_uuid of a supplier order without
  changing status or lines. Works on documents in any status.
  """
  def correct_supplier_order(%SupplierOrder{} = order, attrs) do
    order
    |> SupplierOrder.correction_changeset(attrs)
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Storage folder
  # ---------------------------------------------------------------------------

  @doc """
  Sets the `storage_folder_uuid` on a supplier order.
  Works on documents in any status.
  """
  def set_storage_folder(%SupplierOrder{} = order, storage_folder_uuid) do
    order
    |> SupplierOrder.storage_changeset(%{storage_folder_uuid: storage_folder_uuid})
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Plan of a generation
  # ---------------------------------------------------------------------------

  @doc """
  The plan of generating supplier orders from a posted internal order: the
  supplier of every line and why, the quantity still to order, the choices a
  human may make and a fingerprint of it all. Reads only. See
  `PhoenixKitWarehouse.SupplierOrderPlan`.
  """
  defdelegate plan_from_internal_order(internal_order_uuid, opts \\ []),
    to: SupplierOrderPlan,
    as: :build

  @doc """
  Checks manual supplier choices (`%{line_key => supplier_uuid | "skip"}`)
  against a plan of `plan_from_internal_order/2`: `:ok` or
  `{:error, {:invalid_choice, key}}`.
  """
  defdelegate validate_plan_choices(plan, choices), to: SupplierOrderPlan, as: :validate_choices

  # ---------------------------------------------------------------------------
  # Generate from internal order
  # ---------------------------------------------------------------------------

  @doc """
  What writing `plan` with `choices` creates, without touching the database.
  See `PhoenixKitWarehouse.SupplierOrderPlan.assemble/2`.
  """
  defdelegate assemble(plan, choices), to: SupplierOrderPlan

  @doc """
  The lines of a draft after the lines of `assemble/2` are appended to it.
  See `PhoenixKitWarehouse.SupplierOrderPlan.merge_into/3`.
  """
  defdelegate merge_into(draft_lines, new_lines, opts \\ []), to: SupplierOrderPlan

  @doc """
  The lines an order of `assemble/2` leaves in its draft, what `apply_plan/5`
  writes. See `PhoenixKitWarehouse.SupplierOrderPlan.target_lines/2`.
  """
  defdelegate target_lines(order, internal_order_uuid), to: SupplierOrderPlan

  @doc """
  Writes a plan of `plan_from_internal_order/2` the way a person saw it.

  In one transaction: the advisory lock of the internal order; the internal
  order read again (`{:error, :not_found | :not_posted | :deleted}`); its live
  supplier orders locked FOR UPDATE; the plan built again from them and its
  fingerprint compared with `fingerprint` - when anything it decides on has
  changed, `{:error, {:stale, new_plan}}` and nothing is written; the
  `choices` checked (`{:error, {:invalid_choice, key}}`); then exactly what
  `assemble/2` makes of the plan and the choices is written: a new draft for a
  supplier without a target, the lines appended (`target_lines/2`) to the
  target draft of the others. Nothing goes to the trash.

  `source_refs`: a new draft, and a target that is this order's alone, get one
  ref to the internal order whose `"lines"` are the draft's ordered
  quantities per item after the write; a combined target gets what was
  appended added to this order's ref, its other refs untouched - unless that
  ref has no `"lines"`: it stands for the whole draft, which the plan
  counted, and is left as it is.

  Returns `{:ok, %{supplier_orders: created, appended: drafts_appended_to,
  unassigned_lines: lines, skipped: plan_lines, superseded: []}}`:
  `unassigned_lines` are the supplier order lines of the lines with something
  to order that got no supplier, each with a `"reason"` (`"skipped"` chosen
  by hand, `"ambiguous"`, `"no_supplier"`, `"no_item"`); `skipped` the plan
  lines with nothing to order. `opts` is reserved (`:supersede_drafts` is
  accepted and does nothing).
  """
  @spec apply_plan(term(), String.t(), map(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, map()}
          | {:error,
             {:stale, map()}
             | {:invalid_choice, String.t()}
             | :not_found
             | :not_posted
             | :deleted
             | term()}
  def apply_plan(internal_order_uuid, fingerprint, choices, actor_uuid, _opts \\ [])
      when is_map(choices) do
    write_plan(internal_order_uuid, actor_uuid, fn plan ->
      if plan.fingerprint == fingerprint do
        with :ok <- validate_plan_choices(plan, choices), do: {:ok, choices}
      else
        {:error, {:stale, plan}}
      end
    end)
  end

  @doc """
  Generates draft supplier orders from a posted internal order: what
  `apply_plan/5` writes, with the plan built under the lock and no choices,
  so a line without an automatic supplier is not ordered. See
  `PhoenixKitWarehouse.SupplierOrderPlan` for the supplier of a line and the
  quantity (`required - issued - on hand - already ordered for this order`).

  The internal order is read again by `internal_order.uuid`. One draft per
  (internal order, supplier): what is missing is appended to the live draft
  the supplier already has for this order, a new draft is made only when
  there is none. Nothing goes to the trash; `:supersede_drafts` is accepted
  and does nothing.

  Returns `{:ok, %{supplier_orders: created, appended: drafts_appended_to,
  unassigned_lines: lines, skipped: plan_lines, superseded: []}}` (see
  `apply_plan/5`), `{:error, :not_posted}` for an internal order that is not
  posted, `{:error, :deleted}` for one in the trash, `{:error, :not_found}`.
  Drafts are NOT posted.
  """
  @spec generate_from_internal_order(term(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, map()} | {:error, :not_found | :not_posted | :deleted | term()}
  def generate_from_internal_order(internal_order, actor_uuid, opts \\ [])

  def generate_from_internal_order(%{uuid: internal_order_uuid}, actor_uuid, _opts) do
    write_plan(internal_order_uuid, actor_uuid, fn _plan -> {:ok, %{}} end)
  end

  def generate_from_internal_order(_internal_order, _actor_uuid, _opts), do: {:error, :not_found}

  # The one writing path of a plan. `check` sees the plan built under the
  # locks and answers the choices to write, or an error that rolls back.
  defp write_plan(internal_order_uuid, actor_uuid, check) do
    with {:ok, io_uuid} <- cast_uuid(internal_order_uuid) do
      repo().transaction(fn ->
        lock_internal_order!(io_uuid)

        with {:ok, io} <- SupplierOrderPlan.load_internal_order(io_uuid),
             locked = lock_live_orders(io_uuid),
             plan = SupplierOrderPlan.build_for(io, supplier_orders: locked),
             {:ok, choices} <- check.(plan) do
          assembled = assemble(plan, choices)

          assembled
          |> write_assembled(plan, Map.new(locked, &{&1.uuid, &1}), actor_uuid)
          |> Map.merge(%{
            unassigned_lines: unassigned_lines(assembled, choices),
            skipped: Enum.filter(plan.lines, &Decimal.eq?(&1.to_order, 0)),
            superseded: []
          })
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)
    end
  end

  defp cast_uuid(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  # The live supplier orders of the internal order, locked in uuid order.
  defp lock_live_orders(io_uuid) do
    io_uuid
    |> SupplierOrderPlan.live_supplier_orders_query()
    |> lock_query()
    |> repo().all()
  end

  defp write_assembled(%{orders: orders}, plan, locked, actor_uuid) do
    io_uuid = plan.internal_order.uuid

    {created, appended} =
      Enum.reduce(orders, {[], []}, fn
        %{target: :new} = order, {created, appended} ->
          {[insert_generated!(order, plan, actor_uuid) | created], appended}

        %{target: %{uuid: uuid}} = order, {created, appended} ->
          {created, [append_to_draft!(Map.fetch!(locked, uuid), order, io_uuid) | appended]}
      end)

    %{supplier_orders: Enum.reverse(created), appended: Enum.reverse(appended)}
  end

  defp insert_generated!(order, plan, actor_uuid) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    io_uuid = plan.internal_order.uuid

    %SupplierOrder{}
    |> SupplierOrder.changeset(%{
      supplier_uuid: order.supplier_uuid,
      internal_order_uuid: io_uuid,
      location_uuid: plan.location_uuid,
      lines: order.lines,
      source_refs: [own_ref(nil, io_uuid, order.lines)]
    })
    |> Ecto.Changeset.put_change(:created_by_uuid, actor_uuid)
    |> Ecto.Changeset.put_change(:inserted_at, now)
    |> Ecto.Changeset.put_change(:updated_at, now)
    |> insert_or_rollback()
  end

  # The draft is the locked row the plan (and so `order.target`) was built
  # from.
  defp append_to_draft!(%SupplierOrder{} = draft, order, io_uuid) do
    lines = target_lines(order, io_uuid)

    draft
    |> SupplierOrder.changeset(%{
      lines: lines,
      source_refs: appended_refs(draft, order, io_uuid, lines)
    })
    |> update_or_rollback()
  end

  # A combined draft's ref to this order without `"lines"` stands for the
  # whole draft (the plan counted all of it), so it is left as it is: it
  # then covers what was appended too. Topping it up would turn it into
  # "only what was appended", and the next plan would order the rest again.
  defp appended_refs(draft, order, io_uuid, lines) do
    refs = draft.source_refs || []

    cond do
      single_source?(draft, io_uuid) ->
        [own_ref(refs, io_uuid, lines)]

      CommittedQuantities.whole_document_ref?(refs, "internal_order", io_uuid) ->
        refs

      true ->
        CommittedQuantities.merge_ref(
          refs,
          "internal_order",
          io_uuid,
          ordered_by_item(order.lines)
        )
    end
  end

  # The ref of a draft of this internal order alone: its `"lines"` are what
  # the draft orders per item (the first line of an item, as posting keeps
  # it), so the import and the next plan count the same.
  defp own_ref(refs, io_uuid, lines) do
    base =
      Enum.find(List.wrap(refs), %{"type" => "internal_order", "uuid" => io_uuid}, fn ref ->
        ref["type"] == "internal_order" and ref["uuid"] == io_uuid
      end)

    Map.put(base, "lines", lines |> Enum.uniq_by(& &1["item_uuid"]) |> ordered_by_item())
  end

  defp ordered_by_item(lines) do
    lines
    |> Enum.filter(&is_binary(&1["item_uuid"]))
    |> Enum.reduce(%{}, fn line, acc ->
      qty = parse_decimal(line["ordered_quantity"])
      Map.update(acc, line["item_uuid"], qty, &Decimal.add(&1, qty))
    end)
  end

  defp insert_or_rollback(changeset) do
    case repo().insert(changeset) do
      {:ok, order} -> order
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  defp update_or_rollback(changeset) do
    case repo().update(changeset) do
      {:ok, order} -> order
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  # The lines with something to order that got no supplier, plus the lines
  # of an item missing from the catalogue, as supplier order lines with the
  # reason.
  defp unassigned_lines(assembled, choices) do
    assembled
    |> SupplierOrderPlan.unassigned()
    |> Enum.map(fn line ->
      line
      |> SupplierOrderPlan.order_line()
      |> Map.put("reason", unassigned_reason(line, Map.get(choices, line.key)))
    end)
  end

  defp unassigned_reason(_line, "skip"), do: "skipped"
  defp unassigned_reason(%{reason: reason}, _choice), do: Atom.to_string(reason)

  # ---------------------------------------------------------------------------
  # Import from internal orders
  # ---------------------------------------------------------------------------

  @doc """
  Imports lines from one or more posted internal orders into an existing draft
  supplier order, filtering to items whose resolved supplier matches
  `supplier_order.supplier_uuid`.

  Steps, in one transaction:
  1. Takes the advisory lock of each selected IO (in uuid order, the lock
     `apply_plan/5` takes), then locks the draft's row FOR UPDATE and works
     from that row, not from the given struct.
  2. Loads each selected IO (must be posted and non-deleted).
  3. Enriches lines with the stock on the IO's location; what live supplier
     orders already order for the IO (their `source_refs` `"lines"`) is
     subtracted.
  4. Filters to items whose supplier, by the rules of
     `PhoenixKitWarehouse.SupplierOrderPlan.resolve_line_supplier/2` (the
     ones generation uses), is supplier_order.supplier_uuid.
  5. Merges new lines with existing ones by item_uuid, summing
     required/shortfall/ordered quantities.
  6. Appends `source_refs` entries of type `"internal_order"` for each IO.
  7. Sets `internal_order_uuid` to the first selected IO (primary back-compat).

  Returns:
  - `{:ok, updated_order}` on success.
  - `{:error, :no_supplier}` when the order has no supplier.
  - `{:error, :not_draft}` when the order is not a draft, `{:error, :deleted}`
    when it is in the trash.
  - `{:error, :stale}` when `opts` has `expected_version:` (see
    `update_draft/3`) and the locked row's version differs; nothing is
    imported.
  - `{:error, reason}` on DB failure.
  """
  @spec import_from_internal_orders(
          SupplierOrder.t(),
          [Ecto.UUID.t()],
          Ecto.UUID.t() | nil,
          keyword()
        ) ::
          {:ok, SupplierOrder.t()}
          | {:error, :no_supplier | :not_draft | :deleted | :stale | term()}
  def import_from_internal_orders(supplier_order, io_uuids, actor_uuid, opts \\ [])

  def import_from_internal_orders(
        %SupplierOrder{supplier_uuid: nil},
        _io_uuids,
        _actor_uuid,
        _opts
      ) do
    {:error, :no_supplier}
  end

  def import_from_internal_orders(
        %SupplierOrder{status: status},
        _io_uuids,
        _actor_uuid,
        _opts
      )
      when status != "draft" do
    {:error, :not_draft}
  end

  def import_from_internal_orders(%SupplierOrder{} = supplier_order, io_uuids, _actor_uuid, opts)
      when is_list(io_uuids) do
    repo().transaction(fn ->
      # The internal orders' locks first, then the row: the order of
      # `apply_plan/5`, so the two never wait for each other in a circle.
      for({:ok, uuid} <- Enum.map(io_uuids, &cast_uuid/1), do: uuid)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.each(&lock_internal_order!/1)

      with {:ok, locked} <- lock_status(repo(), supplier_order.uuid, "draft", :not_draft),
           :ok <- check_version(locked, opts) do
        case locked do
          %SupplierOrder{supplier_uuid: nil} -> repo().rollback(:no_supplier)
          _draft -> import_into(locked, load_posted_internal_orders(io_uuids))
        end
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  # Under the locks: what is already ordered, the stock and the draft itself
  # are read here, not taken from the caller's struct.
  defp import_into(%SupplierOrder{} = supplier_order, internal_orders) do
    # Collect all item_uuids across all IOs
    all_item_uuids =
      internal_orders
      |> Enum.flat_map(fn io -> Enum.map(io.lines, & &1["item_uuid"]) end)
      |> Enum.filter(& &1)
      |> Enum.uniq()

    items_by_uuid = load_items_by_uuid(all_item_uuids)

    ctx = %{
      stock_map_by_location: build_stock_map_by_location(internal_orders, all_item_uuids),
      items_by_uuid: items_by_uuid,
      catalogue: SupplierOrderPlan.catalogue_context(Map.values(items_by_uuid)),
      target_supplier_uuid: supplier_order.supplier_uuid,
      committed:
        CommittedQuantities.compute(
          SupplierOrder,
          ["internal_order"],
          Enum.map(internal_orders, & &1.uuid),
          "ordered_quantity"
        )
    }

    {new_lines_by_item, io_contributions} = collect_import_lines(internal_orders, ctx)

    final_lines = merge_import_lines(supplier_order.lines || [], new_lines_by_item)

    # A ref without `"lines"` was netted as the whole draft, which now holds
    # the imported lines too, so it stays as it is (see `appended_refs/4`).
    merged_refs =
      Enum.reduce(internal_orders, supplier_order.source_refs || [], fn io, acc_refs ->
        if CommittedQuantities.whole_document_ref?(acc_refs, "internal_order", io.uuid) do
          acc_refs
        else
          lines_map = Map.get(io_contributions, io.uuid, %{})
          CommittedQuantities.merge_ref(acc_refs, "internal_order", io.uuid, lines_map)
        end
      end)

    # Primary internal_order_uuid — first selected IO (back-compat)
    primary_io_uuid =
      case internal_orders do
        [first | _] -> first.uuid
        [] -> supplier_order.internal_order_uuid
      end

    attrs = %{
      lines: final_lines,
      source_refs: merged_refs,
      internal_order_uuid: primary_io_uuid
    }

    supplier_order
    |> SupplierOrder.changeset(attrs)
    |> update_or_rollback()
  end

  # The selected internal orders, keeping only the ones that are actually
  # posted — an unposted or missing IO contributes nothing to the import.
  defp load_posted_internal_orders(io_uuids) do
    io_uuids
    |> Enum.filter(& &1)
    |> Enum.uniq()
    |> Enum.map(fn uuid ->
      case InternalOrders.get_internal_order(uuid) do
        {:ok, %{status: "posted"} = io} -> io
        _ -> nil
      end
    end)
    |> Enum.filter(& &1)
  end

  defp load_items_by_uuid([]), do: %{}

  defp load_items_by_uuid(item_uuids) do
    item_uuids
    |> Catalogue.list_items_by_uuids()
    |> Map.new(&{&1.uuid, &1})
  end

  # Collects enriched lines belonging to this supplier, merged by item_uuid,
  # netting out quantity already committed to other supplier orders for the
  # same internal order (or this one, on re-import). Returns the merged lines
  # keyed by item, plus what each internal order contributed per item — the
  # latter is what `source_refs` records so the next import nets against it.
  defp collect_import_lines(internal_orders, ctx) do
    Enum.reduce(internal_orders, {%{}, %{}}, fn io, acc ->
      io_committed = Map.get(ctx.committed, io.uuid, %{})
      io_location_uuid = io.location_uuid || StockLedger.default_location_uuid()
      io_stock_map = Map.get(ctx.stock_map_by_location, io_location_uuid, %{})

      Enum.reduce(io.lines, acc, fn line, inner ->
        import_line(inner, line, io, ctx, io_committed, io_stock_map)
      end)
    end)
  end

  # One internal-order line. Nothing is ordered when on-hand stock plus what is
  # already committed elsewhere covers the requirement, when the item is not in
  # the catalogue, or when the item is not this order's supplier's.
  defp import_line({items_acc, io_acc} = acc, line, io, ctx, io_committed, io_stock_map) do
    item_uuid = line["item_uuid"]
    item = Map.get(ctx.items_by_uuid, item_uuid)

    required = parse_decimal(line["required_quantity"])
    on_hand = stock_quantity(io_stock_map, item_uuid)
    base_shortfall = Decimal.max(Decimal.new("0"), Decimal.sub(required, on_hand))
    already = Map.get(io_committed, item_uuid, Decimal.new("0"))
    shortfall = Decimal.max(Decimal.new("0"), Decimal.sub(base_shortfall, already))

    if Decimal.equal?(shortfall, Decimal.new("0")) or is_nil(item) or
         not sole_supplier?(item, ctx) do
      acc
    else
      enriched = build_enriched_line(line, on_hand, shortfall, item)

      items_acc2 =
        Map.update(items_acc, item_uuid, enriched, fn existing ->
          merge_enriched_lines(existing, enriched)
        end)

      io_map = Map.get(io_acc, io.uuid, %{})
      io_map2 = Map.update(io_map, item_uuid, shortfall, &Decimal.add(&1, shortfall))

      {items_acc2, Map.put(io_acc, io.uuid, io_map2)}
    end
  end

  # An item is imported only when its supplier - by the rules of
  # `SupplierOrderPlan.resolve_line_supplier/2`, the ones generation uses - is
  # this order's; an ambiguous item is left for a human to place.
  defp sole_supplier?(item, ctx) do
    SupplierOrderPlan.resolve_line_supplier(item, ctx.catalogue).supplier_uuid ==
      ctx.target_supplier_uuid
  end

  # Existing lines keep their position; an imported line for the same item
  # overrides its quantities. Items only in the import are appended.
  defp merge_import_lines(existing_lines, new_lines_by_item) do
    existing_item_uuids = MapSet.new(existing_lines, & &1["item_uuid"])

    updated_existing =
      Enum.map(existing_lines, fn line ->
        case Map.get(new_lines_by_item, line["item_uuid"]) do
          nil -> line
          imported -> merge_enriched_lines(line, imported)
        end
      end)

    truly_new =
      new_lines_by_item
      |> Map.values()
      |> Enum.filter(fn l -> not MapSet.member?(existing_item_uuids, l["item_uuid"]) end)

    updated_existing ++ truly_new
  end

  # Merges two enriched lines for the same item_uuid by summing quantities.
  defp merge_enriched_lines(existing, new_line) do
    merged = %{
      "item_uuid" => existing["item_uuid"],
      "name" => existing["name"],
      "sku" => existing["sku"],
      "unit" => existing["unit"],
      "catalogue_uuid" => existing["catalogue_uuid"],
      "required_quantity" =>
        Decimal.add(
          parse_decimal(existing["required_quantity"]),
          parse_decimal(new_line["required_quantity"])
        ),
      "on_hand_quantity" => new_line["on_hand_quantity"],
      "shortfall_quantity" =>
        Decimal.add(
          parse_decimal(existing["shortfall_quantity"]),
          parse_decimal(new_line["shortfall_quantity"])
        ),
      "ordered_quantity" =>
        Decimal.add(
          parse_decimal(existing["ordered_quantity"]),
          parse_decimal(new_line["ordered_quantity"])
        ),
      "base_price" => existing["base_price"] || new_line["base_price"]
    }

    LineExplanation.put(
      merged,
      LineExplanation.merge(LineExplanation.get(existing), LineExplanation.get(new_line))
    )
  end

  # ---------------------------------------------------------------------------
  # List posted internal orders (for source picker candidates)
  # ---------------------------------------------------------------------------

  @doc """
  Lists posted (non-deleted) internal orders for use as source-picker candidates
  when importing into a supplier order.

  Returns a list of `%InternalOrder{}` ordered by number descending.
  """
  def list_posted_internal_orders do
    InternalOrder
    |> where([o], o.status == "posted" and is_nil(o.deleted_at))
    |> order_by([o], desc: o.number)
    |> repo().all()
  end

  # ---------------------------------------------------------------------------
  # List suppliers (for supplier select in the form)
  # ---------------------------------------------------------------------------

  @doc """
  Lists all suppliers from the catalogue.
  Returns a list of supplier structs with at least `:uuid` and `:name` fields.
  """
  def list_suppliers do
    Catalogue.list_suppliers()
  end

  # ---------------------------------------------------------------------------
  # Received summary (for supplier order lines tally)
  # ---------------------------------------------------------------------------

  @doc """
  Returns `%{item_uuid => Decimal}` summing `received_quantity` already recorded
  against `supplier_order` across all POSTED, non-deleted goods receipts
  referencing it — either as the primary `supplier_order_uuid` FK, or as a
  secondary `"supplier_order"` source_refs entry.
  """
  def received_summary(%SupplierOrder{uuid: supplier_order_uuid}) do
    Map.get(received_summaries([supplier_order_uuid]), supplier_order_uuid, %{})
  end

  @doc """
  Returns `%{supplier_order_uuid => %{item_uuid => Decimal}}` — for each uuid in
  `supplier_order_uuids`, the received_quantity already recorded against it,
  summed across all POSTED, non-deleted goods receipts referencing it — either
  as the primary `supplier_order_uuid` FK, or as a secondary `"supplier_order"`
  source_refs entry.
  """
  def received_summaries(supplier_order_uuids) do
    wanted = MapSet.new(supplier_order_uuids)

    GoodsReceipt
    |> where([r], r.status == "posted" and is_nil(r.deleted_at))
    |> repo().all()
    |> Enum.reduce(%{}, fn receipt, acc ->
      receipt
      |> matching_supplier_order_uuids(wanted)
      |> Enum.reduce(acc, fn so_uuid, acc2 -> attribute_lines(acc2, so_uuid, receipt.lines) end)
    end)
  end

  # Supplier order uuids (out of `wanted`) that `receipt` counts against —
  # either the primary FK or a secondary "supplier_order" source_refs entry.
  defp matching_supplier_order_uuids(receipt, wanted) do
    secondary_uuids =
      (receipt.source_refs || [])
      |> Enum.filter(&(&1["type"] == "supplier_order"))
      |> Enum.map(& &1["uuid"])

    [receipt.supplier_order_uuid | secondary_uuids]
    |> Enum.filter(&MapSet.member?(wanted, &1))
    |> Enum.uniq()
  end

  # Adds each line's received_quantity (keyed by item_uuid) to `acc[so_uuid]`.
  defp attribute_lines(acc, so_uuid, lines) do
    Enum.reduce(lines, acc, fn line, inner_acc ->
      item_uuid = line["item_uuid"]
      qty = StockLedger.to_decimal(line["received_quantity"] || "0")

      Map.update(inner_acc, so_uuid, %{item_uuid => qty}, fn existing ->
        Map.update(existing, item_uuid, qty, &Decimal.add(&1, qty))
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Locks the row FOR UPDATE and asserts it is still a live row in
  # `expected_status`. A miss is explained by a second read: a trashed row
  # answers `:deleted`, anything else the caller's `error`.
  defp lock_status_step(uuid, expected_status, error) do
    Ecto.Multi.run(Ecto.Multi.new(), :lock_status, fn repo, _changes ->
      lock_status(repo, uuid, expected_status, error)
    end)
  end

  # After `lock_status_step/3`: the locked row against `expected_version:`.
  defp version_step(multi, opts) do
    Ecto.Multi.run(multi, :version, fn _repo, %{lock_status: locked} ->
      with :ok <- check_version(locked, opts), do: {:ok, :current}
    end)
  end

  defp lock_status(repo, uuid, expected_status, error) do
    query =
      from(o in SupplierOrder,
        where: o.uuid == ^uuid and o.status == ^expected_status and is_nil(o.deleted_at),
        lock: "FOR UPDATE"
      )

    case repo.one(query) do
      nil -> {:error, miss_reason(repo, uuid, error)}
      %SupplierOrder{} = locked -> {:ok, locked}
    end
  end

  defp miss_reason(repo, uuid, error) do
    case repo.get(SupplierOrder, uuid) do
      %SupplierOrder{deleted_at: %DateTime{}} -> :deleted
      _ -> error
    end
  end

  # ---------------------------------------------------------------------------
  # One draft per (internal order, supplier): locking and the move to the trash
  # ---------------------------------------------------------------------------

  # Serialises everything that writes what is ordered for one internal order
  # or which of its drafts are live: generation, apply_plan, the import and
  # the swap of a restore.
  defp lock_internal_order!(internal_order_uuid),
    do: DraftTrash.advisory_lock!("phoenix_kit_warehouse:so_for_io:#{internal_order_uuid}")

  defp lock_query(query), do: DraftTrash.lock_query(query)

  defp lock_rows(uuids), do: DraftTrash.lock_rows(SupplierOrder, uuids)

  # Drafts of the internal order alone (see `single_source?/2`). One that
  # refers to another one - or has a ref of an unreadable shape - is kept: a
  # wrongly trashed imported draft would destroy the demand of its other
  # internal orders.
  defp only_internal_order(orders, internal_order_uuid) do
    Enum.filter(orders, &single_source?(&1, internal_order_uuid))
  end

  # The (internal order, supplier) pair a draft is the only one of, or `nil`
  # for a combined draft and one without a supplier or an internal order.
  defp single_pair(%SupplierOrder{internal_order_uuid: io, supplier_uuid: sup} = order)
       when is_binary(io) and is_binary(sup) do
    if single_source?(order, io), do: {io, sup}
  end

  defp single_pair(%SupplierOrder{}), do: nil

  # See `DraftTrash`. Nothing here writes activity: the caller does that after
  # the commit.
  defp trash_drafts(rows, actor_uuid), do: rows |> Enum.map(& &1.uuid) |> trash_ids(actor_uuid)

  defp trash_ids(ids, actor_uuid), do: DraftTrash.trash_ids(SupplierOrder, ids, actor_uuid)

  defp log_trashed(orders, actor_uuid, reason, superseded_by_uuid) do
    Enum.each(orders, fn order ->
      ActivityLog.log_supplier_order_trashed(order,
        actor_uuid: actor_uuid,
        reason: reason,
        superseded_by_uuid: superseded_by_uuid
      )
    end)
  end

  # Returns on-hand quantity as Decimal for a given item_uuid.
  # Each internal order may target a different warehouse, so on-hand
  # quantity must be read per-IO's own location_uuid rather than from a
  # single cross-warehouse snapshot (which would pick an arbitrary
  # location's stock for items held at more than one warehouse).
  defp build_stock_map_by_location(internal_orders, item_uuids) do
    internal_orders
    |> Enum.map(&(&1.location_uuid || StockLedger.default_location_uuid()))
    |> Enum.uniq()
    |> Map.new(fn location_uuid ->
      stock_map =
        item_uuids
        |> StockLedger.stock_for_items_at_location(location_uuid)
        |> Map.new(&{&1.item_uuid, &1})

      {location_uuid, stock_map}
    end)
  end

  defp stock_quantity(stock_map, item_uuid) do
    case Map.get(stock_map, item_uuid) do
      nil -> Decimal.new("0")
      stock -> StockLedger.to_decimal(stock.quantity)
    end
  end

  # Parses a required_quantity value to Decimal via the shared, comma-aware
  # coercion — so "1,5" (et/ru decimals) parses to 1.5 instead of being dropped
  # to 0. Consolidates what was a stricter local parser (see StockLedger.to_decimal/1).
  defp parse_decimal(value), do: StockLedger.to_decimal(value)

  # Builds an enriched line map for a supplier order.
  defp build_enriched_line(line, on_hand, shortfall, item) do
    base_price = item && StockLedger.to_decimal_or_nil(item.base_price)

    enriched = %{
      "item_uuid" => line["item_uuid"],
      "name" => line["name"],
      "sku" => line["sku"],
      "unit" => line["unit"],
      "catalogue_uuid" => line["catalogue_uuid"],
      "required_quantity" => parse_decimal(line["required_quantity"]),
      "on_hand_quantity" => on_hand,
      "shortfall_quantity" => shortfall,
      "ordered_quantity" => shortfall,
      "base_price" => base_price
    }

    LineExplanation.carry(enriched, line)
  end
end
