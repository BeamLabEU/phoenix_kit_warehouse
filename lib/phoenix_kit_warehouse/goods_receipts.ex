defmodule PhoenixKitWarehouse.GoodsReceipts do
  @moduledoc """
  Context for managing goods receipts (goods arrival onto the warehouse).

  A goods receipt registers the arrival of goods from a supplier order and
  INCREASES warehouse stock when posted. There is NO repost — posting a goods
  receipt is an additive delta operation. Correction after posting is limited
  to note and storage_folder only.
  """

  import Ecto.Query

  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.SourceKinds
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrders

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Lists non-deleted goods receipts ordered by number descending (newest first).
  """
  def list_goods_receipts(_opts \\ []) do
    GoodsReceipt
    |> where([r], is_nil(r.deleted_at))
    |> order_by([r], desc: r.number)
    |> repo().all()
  end

  @doc "Returns the goods receipt or raises."
  def get_goods_receipt!(uuid), do: repo().get!(GoodsReceipt, uuid)

  @doc "Returns `{:ok, receipt}` or `{:error, :not_found}`."
  def get_goods_receipt(uuid) do
    case repo().get(GoodsReceipt, uuid) do
      nil -> {:error, :not_found}
      receipt -> {:ok, receipt}
    end
  end

  # ---------------------------------------------------------------------------
  # Draft CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new draft goods receipt.

  `location_uuid` defaults to the configured default warehouse when not given.
  `created_by_uuid` is set programmatically — not via cast.
  """
  def create_goods_receipt(attrs) do
    location_uuid =
      Map.get(attrs, :location_uuid) || Map.get(attrs, "location_uuid") ||
        StockLedger.default_location_uuid()

    attrs = Map.put(attrs, :location_uuid, location_uuid)
    created_by_uuid = Map.get(attrs, :created_by_uuid) || Map.get(attrs, "created_by_uuid")

    %GoodsReceipt{}
    |> GoodsReceipt.changeset(attrs)
    |> Ecto.Changeset.put_change(:created_by_uuid, created_by_uuid)
    |> repo().insert()
  end

  @doc """
  Creates a draft goods receipt from a posted supplier order.

  Lines are copied from the supplier order with:
  - `ordered_quantity` = the supplier order's ordered_quantity (snapshot)
  - `received_quantity` = 0 (default; keeper edits actual received)

  Sets supplier_order_uuid, supplier_uuid, and location_uuid from the source order.
  """
  def create_from_supplier_order(supplier_order, actor_uuid) do
    lines =
      supplier_order.lines
      |> Enum.uniq_by(& &1["item_uuid"])
      |> Enum.map(fn line ->
        %{
          "item_uuid" => line["item_uuid"],
          "name" => line["name"],
          "sku" => line["sku"],
          "unit" => line["unit"],
          "catalogue_uuid" => line["catalogue_uuid"],
          "ordered_quantity" => line["ordered_quantity"],
          "received_quantity" => Decimal.new("0"),
          "unit_value" => line["base_price"] || line["unit_value"]
        }
      end)

    attrs = %{
      supplier_order_uuid: supplier_order.uuid,
      supplier_uuid: supplier_order.supplier_uuid,
      location_uuid: supplier_order.location_uuid || StockLedger.default_location_uuid(),
      lines: lines
    }

    %GoodsReceipt{}
    |> GoodsReceipt.changeset(attrs)
    |> Ecto.Changeset.put_change(:created_by_uuid, actor_uuid)
    |> repo().insert()
  end

  @doc """
  Imports lines from a list of posted supplier orders into an existing draft
  goods receipt.

  Lines are merged by item_uuid (ordered_quantity summed across all SOs).
  supplier_uuid and supplier_order_uuid are taken from the first selected SO
  (primary SO). source_refs are enriched with the full traceability chain —
  each selected supplier order, the internal order(s) that fed it, and the
  customer order(s)/sub-order(s) that fed those — and saved via update_draft.

  Returns `{:ok, updated_receipt}` or `{:error, reason}`.
  """
  def import_from_supplier_orders(%GoodsReceipt{status: "draft"}, [], _actor_uuid) do
    {:error, :no_selection}
  end

  def import_from_supplier_orders(%GoodsReceipt{status: "draft"} = receipt, so_uuids, _actor_uuid)
      when is_list(so_uuids) do
    supplier_orders =
      so_uuids
      |> Enum.map(&SupplierOrders.get_supplier_order/1)
      |> Enum.flat_map(fn
        {:ok, so} -> [so]
        _ -> []
      end)

    case supplier_orders do
      [] ->
        {:error, :not_found}

      [primary | _] = orders ->
        new_lines = merge_lines_from_orders(orders)
        existing_lines = receipt.lines

        merged_lines = merge_by_item_uuid(existing_lines, new_lines)

        existing_refs = receipt.source_refs || []
        new_refs = derive_chain_refs(orders)

        # De-duplicate refs by {type, uuid} to avoid double-adding the same document
        all_refs =
          (existing_refs ++ new_refs)
          |> Enum.uniq_by(&{&1["type"], &1["uuid"]})

        attrs = %{
          supplier_order_uuid: receipt.supplier_order_uuid || primary.uuid,
          supplier_uuid: receipt.supplier_uuid || primary.supplier_uuid,
          lines: merged_lines,
          source_refs: all_refs
        }

        update_draft(receipt, attrs)
    end
  end

  def import_from_supplier_orders(%GoodsReceipt{}, _so_uuids, _actor_uuid) do
    {:error, :not_draft}
  end

  # Builds the deduplicated 3-tier ref chain for a set of supplier orders:
  # the supplier orders themselves, the internal order(s) that fed each one
  # (from source_refs, falling back to the legacy internal_order_uuid FK),
  # and the customer order(s)/sub-order(s) that fed those internal orders.
  defp derive_chain_refs(supplier_orders) do
    so_refs = Enum.map(supplier_orders, &%{"type" => "supplier_order", "uuid" => &1.uuid})

    io_uuids =
      supplier_orders
      |> Enum.flat_map(fn so ->
        refs_io_uuids =
          (so.source_refs || [])
          |> Enum.filter(&(&1["type"] == "internal_order"))
          |> Enum.map(& &1["uuid"])

        if refs_io_uuids == [] and so.internal_order_uuid,
          do: [so.internal_order_uuid],
          else: refs_io_uuids
      end)
      |> Enum.uniq()

    internal_orders =
      io_uuids
      |> Enum.map(&InternalOrders.get_internal_order/1)
      |> Enum.flat_map(fn
        {:ok, io} -> [io]
        _ -> []
      end)

    io_refs = Enum.map(internal_orders, &%{"type" => "internal_order", "uuid" => &1.uuid})

    top_refs =
      internal_orders
      |> Enum.flat_map(fn io -> io.source_refs || [] end)
      |> Enum.filter(&(&1["type"] in ["order", "sub_order"]))

    (so_refs ++ io_refs ++ top_refs)
    |> Enum.uniq_by(&{&1["type"], &1["uuid"]})
  end

  # Builds a flat list of receipt lines from multiple supplier orders, netting
  # out quantity already received against each SO via posted goods receipts.
  defp merge_lines_from_orders(orders) do
    received_by_so = SupplierOrders.received_summaries(Enum.map(orders, & &1.uuid))

    orders
    |> Enum.flat_map(fn so ->
      received = Map.get(received_by_so, so.uuid, %{})

      so.lines
      |> Enum.uniq_by(& &1["item_uuid"])
      |> Enum.map(fn line ->
        item_uuid = line["item_uuid"]
        ordered = StockLedger.to_decimal(line["ordered_quantity"])
        already_received = Map.get(received, item_uuid, Decimal.new("0"))
        remaining = Decimal.max(Decimal.new("0"), Decimal.sub(ordered, already_received))

        %{
          "item_uuid" => item_uuid,
          "name" => line["name"],
          "sku" => line["sku"],
          "unit" => line["unit"],
          "catalogue_uuid" => line["catalogue_uuid"],
          "ordered_quantity" => remaining,
          "received_quantity" => Decimal.new("0"),
          "unit_value" => line["base_price"] || line["unit_value"]
        }
      end)
      |> Enum.reject(&Decimal.equal?(&1["ordered_quantity"], Decimal.new("0")))
    end)
  end

  # Merges new_lines into existing_lines by item_uuid:
  # - Existing lines whose item_uuid appears in new_lines get ordered_quantity summed.
  # - New lines for items not yet in existing_lines are appended (qty summed across SOs).
  defp merge_by_item_uuid(existing_lines, new_lines) do
    # Build map: item_uuid => {representative_line, total_ordered_qty}
    new_by_uuid =
      Enum.reduce(new_lines, %{}, fn line, acc ->
        item_uuid = line["item_uuid"]
        qty = StockLedger.to_decimal(line["ordered_quantity"] || "0")

        case Map.get(acc, item_uuid) do
          nil ->
            Map.put(acc, item_uuid, {line, qty})

          {existing_line, existing_qty} ->
            Map.put(acc, item_uuid, {existing_line, Decimal.add(existing_qty, qty)})
        end
      end)

    existing_uuids = MapSet.new(existing_lines, & &1["item_uuid"])

    # Update quantities for items already in existing_lines
    updated_existing =
      Enum.map(existing_lines, fn line ->
        item_uuid = line["item_uuid"]

        case Map.get(new_by_uuid, item_uuid) do
          nil ->
            line

          {_representative, added_qty} ->
            existing_ordered = StockLedger.to_decimal(line["ordered_quantity"] || "0")
            Map.put(line, "ordered_quantity", Decimal.add(existing_ordered, added_qty))
        end
      end)

    # Append lines for items not yet in existing_lines (in SO insertion order)
    appended =
      new_lines
      |> Enum.map(& &1["item_uuid"])
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(existing_uuids, &1))
      |> Enum.map(fn uuid ->
        {representative, total_qty} = Map.fetch!(new_by_uuid, uuid)
        Map.put(representative, "ordered_quantity", total_qty)
      end)

    updated_existing ++ appended
  end

  @doc """
  Updates a draft goods receipt. Returns `{:error, :not_draft}` when not in
  draft status.
  """
  def update_draft(%GoodsReceipt{status: "draft"} = receipt, attrs) do
    receipt
    |> GoodsReceipt.changeset(attrs)
    |> repo().update()
  end

  def update_draft(%GoodsReceipt{}, _attrs), do: {:error, :not_draft}

  @doc """
  Manually attaches a traceability reference to a goods receipt.

  `"internal_order"` and `"supplier_order"` are always valid (intra-module).
  Any other `type` must be a kind registered via `PhoenixKitWarehouse.SourceKinds`.
  Pure metadata — does not touch `lines` and is not gated to draft status.
  A duplicate `{type, uuid}` pair is a no-op.
  """
  def add_source_ref(%GoodsReceipt{} = receipt, type, uuid) do
    if valid_ref_type?(type) do
      new_ref = %{"type" => type, "uuid" => uuid}

      refs =
        ((receipt.source_refs || []) ++ [new_ref])
        |> Enum.uniq_by(&{&1["type"], &1["uuid"]})

      receipt
      |> GoodsReceipt.changeset(%{source_refs: refs})
      |> repo().update()
    else
      {:error, :invalid_ref_type}
    end
  end

  defp valid_ref_type?(type) when type in ["internal_order", "supplier_order"], do: true
  defp valid_ref_type?(type), do: type in Enum.map(SourceKinds.list_kinds(), & &1.kind)

  @doc """
  Detaches a traceability reference from a goods receipt. No-op when the
  `{type, uuid}` pair isn't present.
  """
  def remove_source_ref(%GoodsReceipt{} = receipt, type, uuid) do
    refs = Enum.reject(receipt.source_refs || [], &(&1["type"] == type and &1["uuid"] == uuid))

    receipt
    |> GoodsReceipt.changeset(%{source_refs: refs})
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Posting — INCREASES stock
  # ---------------------------------------------------------------------------

  @doc """
  Posts a goods receipt in an `Ecto.Multi` transaction. INCREASES warehouse stock.

  - Locks the row FOR UPDATE and re-checks status == "draft" (prevents double-posting).
  - Deduplicates lines by item_uuid.
  - For each line with received_quantity > 0:
    - Captures `previous_quantity` = current on-hand for audit.
    - Calls `StockLedger.receive_quantity/3` (additive stock delta).
  - Lines with received_quantity == 0 contribute no stock change.
  - Merges `previous_quantity` into the persisted lines (audit trail).
  - Flips status → "posted", sets posted_at and performed_by_uuid.

  Returns `{:error, :not_draft}` for non-draft receipts.
  """
  def post_goods_receipt(%GoodsReceipt{status: status}, _performed_by_uuid)
      when status != "draft" do
    {:error, :not_draft}
  end

  def post_goods_receipt(%GoodsReceipt{} = receipt, performed_by_uuid) do
    multi =
      receipt.uuid
      |> lock_status_step("draft", :not_draft)
      |> Ecto.Multi.run(:post, fn repo, %{lock_status: locked} ->
        apply_stock_and_post(locked, performed_by_uuid, repo)
      end)

    case repo().transaction(multi) do
      {:ok, %{post: posted}} -> {:ok, posted}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  defp apply_stock_and_post(locked, performed_by_uuid, repo) do
    lines = Enum.uniq_by(locked.lines, & &1["item_uuid"])

    item_uuids = lines |> Enum.map(& &1["item_uuid"]) |> Enum.filter(& &1)

    stock_map =
      item_uuids
      |> StockLedger.stock_for_items()
      |> Map.new(&{&1.item_uuid, &1})

    case receive_lines(lines, stock_map, locked.location_uuid, repo) do
      {:ok, audited_lines} ->
        locked
        |> GoodsReceipt.post_changeset(audited_lines, performed_by_uuid)
        |> repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_lines(lines, stock_map, location_uuid, repo) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      item_uuid = line["item_uuid"]
      received_qty = StockLedger.to_decimal(line["received_quantity"])

      prior = Map.get(stock_map, item_uuid)
      previous_quantity = if prior, do: prior.quantity, else: Decimal.new("0")
      audited_line = Map.put(line, "previous_quantity", previous_quantity)

      case maybe_receive(item_uuid, received_qty, location_uuid, repo) do
        :skip -> {:cont, {:ok, acc ++ [audited_line]}}
        {:ok, _stock} -> {:cont, {:ok, acc ++ [audited_line]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_receive(item_uuid, received_qty, location_uuid, repo) do
    if Decimal.equal?(received_qty, Decimal.new("0")) do
      :skip
    else
      StockLedger.receive_quantity(item_uuid, received_qty,
        location_uuid: location_uuid,
        repo: repo
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Soft delete
  # ---------------------------------------------------------------------------

  @doc "Soft-deletes a draft goods receipt. Returns {:error, :not_draft} for posted documents."
  def soft_delete(%GoodsReceipt{status: "draft"} = receipt, actor_uuid) do
    receipt
    |> GoodsReceipt.soft_delete_changeset(%{
      deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      deleted_by_uuid: actor_uuid
    })
    |> repo().update()
  end

  def soft_delete(%GoodsReceipt{}, _actor_uuid), do: {:error, :not_draft}

  # ---------------------------------------------------------------------------
  # Correction (note + storage_folder on posted)
  # ---------------------------------------------------------------------------

  @doc """
  Corrects the note and/or storage_folder_uuid of a goods receipt without
  changing status or lines. Works on documents in any status.
  Lines are immutable once posted.
  """
  def correct_goods_receipt(%GoodsReceipt{} = receipt, attrs) do
    receipt
    |> GoodsReceipt.correction_changeset(attrs)
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Storage folder
  # ---------------------------------------------------------------------------

  @doc """
  Sets the `storage_folder_uuid` on a goods receipt.
  Works on documents in any status.
  """
  def set_storage_folder(%GoodsReceipt{} = receipt, storage_folder_uuid) do
    receipt
    |> GoodsReceipt.storage_changeset(%{storage_folder_uuid: storage_folder_uuid})
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp lock_status_step(uuid, expected_status, error) do
    Ecto.Multi.run(Ecto.Multi.new(), :lock_status, fn repo, _changes ->
      query =
        from(r in GoodsReceipt,
          where: r.uuid == ^uuid and r.status == ^expected_status,
          lock: "FOR UPDATE"
        )

      case repo.one(query) do
        nil -> {:error, error}
        %GoodsReceipt{} = locked -> {:ok, locked}
      end
    end)
  end
end
