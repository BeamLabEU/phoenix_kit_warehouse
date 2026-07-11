defmodule PhoenixKitWarehouse.Transfers do
  @moduledoc """
  Context for managing transfers (stock moved between two warehouses).

  A transfer moves stock from a `source_location_uuid` warehouse to a
  `destination_location_uuid` warehouse via two separate atomic postings —
  not one shared transaction — because the goods physically leave the
  source and arrive at the destination at different points in time:

    * `ship_transfer/2` (draft -> in_transit) DECREASES stock at the source
      (conditional decrement — the whole Multi rolls back if any line has
      insufficient stock, mirroring `GoodsIssues.post_goods_issue/2`).
    * `receive_transfer/2` (in_transit -> done) INCREASES stock at the
      destination (additive delta, mirroring
      `GoodsReceipts.post_goods_receipt/2`).

  Both locations must be chosen and distinct before a transfer can ship —
  `ship_transfer/2` and `receive_transfer/2` return `{:error,
  :locations_required}` up front rather than silently falling back to the
  configured default warehouse.

  A transfer can also be cancelled via `cancel_transfer/2`, from `draft`
  (no postings — nothing moved yet) or from `in_transit` (credits stock back
  to the source, reversing `ship_transfer/2`). It cannot be cancelled once
  `done` (received) or already `cancelled`.
  """

  import Ecto.Query

  alias PhoenixKitWarehouse.SourceKinds
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Transfer

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Lists non-deleted transfers ordered by number descending (newest first).
  """
  def list_transfers(_opts \\ []) do
    Transfer
    |> where([t], is_nil(t.deleted_at))
    |> order_by([t], desc: t.number)
    |> repo().all()
  end

  @doc "Returns the transfer or raises."
  def get_transfer!(uuid), do: repo().get!(Transfer, uuid)

  @doc "Returns `{:ok, transfer}` or `{:error, :not_found}`."
  def get_transfer(uuid) do
    case repo().get(Transfer, uuid) do
      nil -> {:error, :not_found}
      transfer -> {:ok, transfer}
    end
  end

  # ---------------------------------------------------------------------------
  # Draft CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new draft transfer.

  Unlike `GoodsIssues.create_goods_issue/1` and friends, `source_location_uuid`
  and `destination_location_uuid` do NOT default to the configured default
  warehouse — a transfer is meaningless without two *specific*, distinct
  warehouses, so both are left `nil` when not supplied in `attrs`. The UI
  requires both to be chosen before the transfer can be shipped (see
  `ship_transfer/2`).

  `created_by_uuid` is set programmatically — not via cast.
  """
  def create_transfer(attrs) do
    created_by_uuid = Map.get(attrs, :created_by_uuid) || Map.get(attrs, "created_by_uuid")

    %Transfer{}
    |> Transfer.changeset(attrs)
    |> Ecto.Changeset.put_change(:created_by_uuid, created_by_uuid)
    |> repo().insert()
  end

  @doc """
  Updates a draft transfer. Returns `{:error, :not_draft}` when not in draft
  status. Locations may be left/set to `nil` — see `create_transfer/1`.
  """
  def update_draft(%Transfer{status: "draft"} = transfer, attrs) do
    transfer
    |> Transfer.changeset(attrs)
    |> repo().update()
  end

  def update_draft(%Transfer{}, _attrs), do: {:error, :not_draft}

  @doc """
  Manually attaches a traceability reference to a transfer.

  `type` must be a kind registered via `PhoenixKitWarehouse.SourceKinds`.
  Pure metadata — does not touch `lines` and is not gated to draft status.
  A duplicate `{type, uuid}` pair is a no-op.
  """
  def add_source_ref(%Transfer{} = transfer, type, uuid) do
    if registered_kind?(type) do
      new_ref = %{"type" => type, "uuid" => uuid}

      refs =
        ((transfer.source_refs || []) ++ [new_ref])
        |> Enum.uniq_by(&{&1["type"], &1["uuid"]})

      transfer
      |> Transfer.changeset(%{source_refs: refs})
      |> repo().update()
    else
      {:error, :invalid_ref_type}
    end
  end

  defp registered_kind?(type), do: type in Enum.map(SourceKinds.list_kinds(), & &1.kind)

  @doc """
  Detaches a traceability reference from a transfer. No-op when the
  `{type, uuid}` pair isn't present.
  """
  def remove_source_ref(%Transfer{} = transfer, type, uuid) do
    refs = Enum.reject(transfer.source_refs || [], &(&1["type"] == type and &1["uuid"] == uuid))

    transfer
    |> Transfer.changeset(%{source_refs: refs})
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Shipping — DECREASES stock at the source
  # ---------------------------------------------------------------------------

  @doc """
  Ships a transfer in an `Ecto.Multi` transaction (draft -> in_transit).
  DECREASES stock at `source_location_uuid`.

  - Returns `{:error, :locations_required}` BEFORE touching the database
    when `source_location_uuid` or `destination_location_uuid` is `nil`, or
    when they're equal to each other — `StockLedger.issue_quantity/3` would
    otherwise silently fall back to the configured default warehouse for a
    `nil` location, a materially different (and wrong) outcome from "no
    location chosen yet".
  - Locks the row FOR UPDATE and re-checks status == "draft" (prevents
    double-shipping).
  - Deduplicates lines by item_uuid.
  - For each line with transfer_quantity > 0:
    - Captures `previous_source_quantity` = current on-hand at the source
      for audit.
    - Calls `StockLedger.issue_quantity/3` (conditional decrement).
    - If ANY line returns `{:error, {:insufficient_stock, _}}`, the WHOLE
      Multi rolls back: stock is unchanged and the document stays draft.
  - Lines with transfer_quantity == 0 contribute no stock change.
  - Flips status -> "in_transit", sets shipped_at and performed_by_uuid.

  Returns `{:error, :not_draft}` for non-draft transfers.
  """
  def ship_transfer(%Transfer{status: status}, _performed_by_uuid) when status != "draft" do
    {:error, :not_draft}
  end

  def ship_transfer(%Transfer{} = transfer, performed_by_uuid) do
    with :ok <- validate_locations(transfer) do
      multi =
        transfer.uuid
        |> lock_status_step("draft", :not_draft)
        |> Ecto.Multi.run(:ship, fn repo, %{lock_status: locked} ->
          apply_ship(locked, performed_by_uuid, repo)
        end)

      case repo().transaction(multi) do
        {:ok, %{ship: shipped}} -> {:ok, shipped}
        {:error, _op, reason, _changes} -> {:error, reason}
      end
    end
  end

  defp apply_ship(locked, performed_by_uuid, repo) do
    lines = Enum.uniq_by(locked.lines, & &1["item_uuid"])
    item_uuids = lines |> Enum.map(& &1["item_uuid"]) |> Enum.filter(& &1)

    stock_map =
      item_uuids
      |> StockLedger.stock_for_items_at_location(locked.source_location_uuid, repo)
      |> Map.new(&{&1.item_uuid, &1})

    mover = fn item_uuid, qty ->
      StockLedger.issue_quantity(item_uuid, qty,
        location_uuid: locked.source_location_uuid,
        repo: repo
      )
    end

    case apply_lines(lines, stock_map, "previous_source_quantity", mover) do
      {:ok, audited_lines} ->
        locked
        |> Transfer.ship_changeset(audited_lines, performed_by_uuid)
        |> repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Receiving — INCREASES stock at the destination
  # ---------------------------------------------------------------------------

  @doc """
  Receives a transfer in an `Ecto.Multi` transaction (in_transit -> done).
  INCREASES stock at `destination_location_uuid`.

  - Returns `{:error, :locations_required}` when either location is `nil`
    or they're equal to each other. Both are guaranteed to already be set at
    this stage (the transfer went through `ship_transfer/2` first), but the
    check is cheap and guards against manually-corrupted data.
  - Locks the row FOR UPDATE and re-checks status == "in_transit" (prevents
    double-receiving).
  - Deduplicates lines by item_uuid.
  - For each line with transfer_quantity > 0:
    - Captures `previous_destination_quantity` = current on-hand at the
      destination for audit.
    - Calls `StockLedger.receive_quantity/3` (additive stock delta — does
      NOT touch the source again).
  - Lines with transfer_quantity == 0 contribute no stock change.
  - Flips status -> "done", sets received_at and performed_by_uuid.

  Returns `{:error, :not_in_transit}` for transfers not in `in_transit` status.
  """
  def receive_transfer(%Transfer{status: status}, _performed_by_uuid)
      when status != "in_transit" do
    {:error, :not_in_transit}
  end

  def receive_transfer(%Transfer{} = transfer, performed_by_uuid) do
    with :ok <- validate_locations(transfer) do
      multi =
        transfer.uuid
        |> lock_status_step("in_transit", :not_in_transit)
        |> Ecto.Multi.run(:receive, fn repo, %{lock_status: locked} ->
          apply_receive(locked, performed_by_uuid, repo)
        end)

      case repo().transaction(multi) do
        {:ok, %{receive: received}} -> {:ok, received}
        {:error, _op, reason, _changes} -> {:error, reason}
      end
    end
  end

  defp apply_receive(locked, performed_by_uuid, repo) do
    lines = Enum.uniq_by(locked.lines, & &1["item_uuid"])
    item_uuids = lines |> Enum.map(& &1["item_uuid"]) |> Enum.filter(& &1)

    stock_map =
      item_uuids
      |> StockLedger.stock_for_items_at_location(locked.destination_location_uuid, repo)
      |> Map.new(&{&1.item_uuid, &1})

    mover = fn item_uuid, qty ->
      StockLedger.receive_quantity(item_uuid, qty,
        location_uuid: locked.destination_location_uuid,
        repo: repo
      )
    end

    case apply_lines(lines, stock_map, "previous_destination_quantity", mover) do
      {:ok, audited_lines} ->
        locked
        |> Transfer.receive_changeset(audited_lines, performed_by_uuid)
        |> repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Shared line-walker for all three transfer operations (ship, receive, and
  # cancel's reversal-from-in_transit leg): snapshots the prior on-hand
  # quantity (under `audit_key`) for every line, skips zero-quantity lines
  # (no stock call at all), and halts the whole reduction — returning
  # `{:error, reason}` — the moment `mover.(item_uuid, qty)` does. `mover` is
  # a 2-arity closure already carrying the location/repo for its leg
  # (`StockLedger.issue_quantity/3` for shipping, `receive_quantity/3` for
  # receiving and for cancel's source credit-back).
  defp apply_lines(lines, stock_map, audit_key, mover) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      item_uuid = line["item_uuid"]
      qty = StockLedger.to_decimal(line["transfer_quantity"])

      prior = Map.get(stock_map, item_uuid)
      previous_quantity = if prior, do: prior.quantity, else: Decimal.new("0")
      audited_line = Map.put(line, audit_key, previous_quantity)

      case maybe_move(mover, item_uuid, qty) do
        :skip -> {:cont, {:ok, acc ++ [audited_line]}}
        {:ok, _} -> {:cont, {:ok, acc ++ [audited_line]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_move(mover, item_uuid, qty) do
    if Decimal.equal?(qty, Decimal.new("0")) do
      :skip
    else
      mover.(item_uuid, qty)
    end
  end

  # Shared by ship_transfer/2 and receive_transfer/2 — both locations must be
  # set and distinct before stock can move in either direction.
  defp validate_locations(%Transfer{
         source_location_uuid: source_location_uuid,
         destination_location_uuid: destination_location_uuid
       }) do
    cond do
      is_nil(source_location_uuid) or is_nil(destination_location_uuid) ->
        {:error, :locations_required}

      source_location_uuid == destination_location_uuid ->
        {:error, :locations_required}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Cancellation
  # ---------------------------------------------------------------------------

  @doc """
  Cancels a transfer.

  - From `draft`: NO stock postings — the goods never physically moved, so
    cancelling just locks the row FOR UPDATE (re-checking status == "draft",
    guarding against a concurrent ship) and flips status -> "cancelled" via
    `Transfer.cancel_changeset/2`.
  - From `in_transit`: reverses the `ship_transfer/2` posting. Locks the row
    FOR UPDATE (re-checking status == "in_transit") and, for each line with
    transfer_quantity > 0, credits the quantity BACK to `source_location_uuid`
    via `StockLedger.receive_quantity/3` (additive — unlike issuing, this
    cannot fail on insufficient stock). Captures `reversed_source_quantity`
    (the source's on-hand quantity immediately before the credit) on each
    line for audit, mirroring `previous_source_quantity`/
    `previous_destination_quantity` on the other two legs. Does not touch
    the destination — nothing arrived there yet.
  - From `done` or already `cancelled`: returns `{:error, :not_cancellable}`
    — a completed transfer can't be un-received, and a cancelled transfer
    can't be cancelled twice.
  """
  def cancel_transfer(%Transfer{status: "draft"} = transfer, performed_by_uuid) do
    multi =
      transfer.uuid
      |> lock_status_step("draft", :not_cancellable)
      |> Ecto.Multi.run(:cancel, fn repo, %{lock_status: locked} ->
        locked
        |> Transfer.cancel_changeset(%{performed_by_uuid: performed_by_uuid})
        |> repo.update()
      end)

    case repo().transaction(multi) do
      {:ok, %{cancel: cancelled}} -> {:ok, cancelled}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  def cancel_transfer(%Transfer{status: "in_transit"} = transfer, performed_by_uuid) do
    multi =
      transfer.uuid
      |> lock_status_step("in_transit", :not_cancellable)
      |> Ecto.Multi.run(:cancel, fn repo, %{lock_status: locked} ->
        apply_cancel(locked, performed_by_uuid, repo)
      end)

    case repo().transaction(multi) do
      {:ok, %{cancel: cancelled}} -> {:ok, cancelled}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  def cancel_transfer(%Transfer{status: status}, _performed_by_uuid)
      when status in ["done", "cancelled"] do
    {:error, :not_cancellable}
  end

  # Reverses ship_transfer/2's source decrement: credits transfer_quantity
  # back to source_location_uuid for every line (skipping zero-quantity
  # lines), snapshotting the pre-credit source quantity under
  # "reversed_source_quantity".
  defp apply_cancel(locked, performed_by_uuid, repo) do
    lines = Enum.uniq_by(locked.lines, & &1["item_uuid"])
    item_uuids = lines |> Enum.map(& &1["item_uuid"]) |> Enum.filter(& &1)

    stock_map =
      item_uuids
      |> StockLedger.stock_for_items_at_location(locked.source_location_uuid, repo)
      |> Map.new(&{&1.item_uuid, &1})

    mover = fn item_uuid, qty ->
      StockLedger.receive_quantity(item_uuid, qty,
        location_uuid: locked.source_location_uuid,
        repo: repo
      )
    end

    case apply_lines(lines, stock_map, "reversed_source_quantity", mover) do
      {:ok, audited_lines} ->
        locked
        |> Transfer.cancel_changeset(%{
          performed_by_uuid: performed_by_uuid,
          lines: audited_lines
        })
        |> repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Soft delete
  # ---------------------------------------------------------------------------

  @doc "Soft-deletes a draft transfer. Returns {:error, :not_draft} for shipped/received/cancelled transfers."
  def soft_delete_transfer(%Transfer{status: "draft"} = transfer, actor_uuid) do
    transfer
    |> Transfer.soft_delete_changeset(%{
      deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      deleted_by_uuid: actor_uuid
    })
    |> repo().update()
  end

  def soft_delete_transfer(%Transfer{}, _actor_uuid), do: {:error, :not_draft}

  # ---------------------------------------------------------------------------
  # Correction (note + storage_folder, any status)
  # ---------------------------------------------------------------------------

  @doc """
  Corrects the note and/or storage_folder_uuid of a transfer without
  changing status or lines. Works on documents in any status.
  """
  def correct_transfer(%Transfer{} = transfer, attrs) do
    transfer
    |> Transfer.correction_changeset(attrs)
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Storage folder
  # ---------------------------------------------------------------------------

  @doc """
  Sets the `storage_folder_uuid` on a transfer. Works on documents in any status.
  """
  def set_storage_folder(%Transfer{} = transfer, storage_folder_uuid) do
    transfer
    |> Transfer.storage_changeset(%{storage_folder_uuid: storage_folder_uuid})
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp lock_status_step(uuid, expected_status, error) do
    Ecto.Multi.run(Ecto.Multi.new(), :lock_status, fn repo, _changes ->
      query =
        from(t in Transfer,
          where: t.uuid == ^uuid and t.status == ^expected_status,
          lock: "FOR UPDATE"
        )

      case repo.one(query) do
        nil -> {:error, error}
        %Transfer{} = locked -> {:ok, locked}
      end
    end)
  end
end
