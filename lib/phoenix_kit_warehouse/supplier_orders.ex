defmodule PhoenixKitWarehouse.SupplierOrders do
  @moduledoc """
  Context for managing supplier orders (purchase orders to a single supplier).

  Supplier orders are generated (semi-automatically) from posted internal orders.
  Posting has NO stock effect — goods receipt will do that.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.CommittedQuantities
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrder

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Lists non-deleted supplier orders ordered by number descending (newest first).
  """
  def list_supplier_orders(_opts \\ []) do
    SupplierOrder
    |> where([o], is_nil(o.deleted_at))
    |> order_by([o], desc: o.number)
    |> repo().all()
  end

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
  Updates a draft supplier order. Returns `{:error, :not_draft}` when not in
  draft status.

  Locks the row FOR UPDATE and re-checks status == "draft" in the DB (not
  just the in-memory struct) so a stale tab cannot overwrite an order that
  was posted concurrently by another tab/user.
  """
  def update_draft(%SupplierOrder{uuid: uuid}, attrs) do
    multi =
      uuid
      |> lock_status_step("draft", :not_draft)
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
  A duplicate `{type, uuid}` pair is a no-op.
  """
  def add_source_ref(%SupplierOrder{} = order, type, uuid) when type in ["internal_order"] do
    new_ref = %{"type" => type, "uuid" => uuid}

    refs =
      ((order.source_refs || []) ++ [new_ref])
      |> Enum.uniq_by(&{&1["type"], &1["uuid"]})

    order
    |> SupplierOrder.changeset(%{source_refs: refs})
    |> repo().update()
  end

  @doc """
  Detaches a traceability reference from a supplier order. No-op when the
  `{type, uuid}` pair isn't present.
  """
  def remove_source_ref(%SupplierOrder{} = order, type, uuid) do
    refs = Enum.reject(order.source_refs || [], &(&1["type"] == type and &1["uuid"] == uuid))

    order
    |> SupplierOrder.changeset(%{source_refs: refs})
    |> repo().update()
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

  Returns `{:error, :not_draft}` for non-draft orders.
  """
  def post_supplier_order(%SupplierOrder{status: status}, _performed_by_uuid)
      when status != "draft" do
    {:error, :not_draft}
  end

  def post_supplier_order(%SupplierOrder{} = order, performed_by_uuid) do
    multi =
      order.uuid
      |> lock_status_step("draft", :not_draft)
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

  @doc "Soft-deletes a draft supplier order. Returns {:error, :not_draft} for posted documents."
  def soft_delete_supplier_order(%SupplierOrder{status: "draft"} = order, actor_uuid) do
    order
    |> SupplierOrder.soft_delete_changeset(%{
      deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      deleted_by_uuid: actor_uuid
    })
    |> repo().update()
  end

  def soft_delete_supplier_order(%SupplierOrder{}, _actor_uuid), do: {:error, :not_draft}

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
  # Generate from internal order
  # ---------------------------------------------------------------------------

  @doc """
  Generates draft supplier orders from a posted internal order.

  All-or-nothing inside a single `Ecto.Multi` transaction:

  1. Computes net shortfall per line:
       shortfall = max(0, required − on_hand)
     Lines with shortfall == 0 are dropped (fully stocked).

  2. Resolves supplier per material via the item's manufacturer:
     - Exactly 1 linked supplier → line is assigned to that supplier.
     - 0 OR >1 linked suppliers → line goes to the "unassigned" bucket
       (never auto-picked from multiple suppliers).

  3. Groups assigned lines by supplier_uuid → creates ONE DRAFT per supplier.
     Line shape carries: on_hand_quantity, shortfall_quantity,
     ordered_quantity (= shortfall, keeper edits later),
     base_price (catalogue base price), required_quantity.

  Returns `{:ok, %{supplier_orders: [...drafts...], unassigned_lines: [...]}}`.
  Drafts are NOT posted.
  """
  def generate_from_internal_order(internal_order, actor_uuid) do
    item_uuids =
      internal_order.lines
      |> Enum.map(& &1["item_uuid"])
      |> Enum.filter(& &1)
      |> Enum.uniq()

    location_uuid = internal_order.location_uuid || StockLedger.default_location_uuid()

    stock_map =
      item_uuids
      |> StockLedger.stock_for_items_at_location(location_uuid)
      |> Map.new(&{&1.item_uuid, &1})

    items_by_uuid =
      if item_uuids == [] do
        %{}
      else
        item_uuids
        |> Catalogue.list_items_by_uuids()
        |> Map.new(&{&1.uuid, &1})
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {assigned_by_supplier, unassigned_lines} =
      internal_order.lines
      |> Enum.reduce({%{}, []}, fn line, {assigned_acc, unassigned_acc} ->
        item_uuid = line["item_uuid"]
        item = Map.get(items_by_uuid, item_uuid)

        required = parse_decimal(line["required_quantity"])
        on_hand = stock_quantity(stock_map, item_uuid)
        shortfall = Decimal.max(Decimal.new("0"), Decimal.sub(required, on_hand))

        cond do
          Decimal.equal?(shortfall, Decimal.new("0")) ->
            # Zero shortfall — drop this line entirely
            {assigned_acc, unassigned_acc}

          is_nil(item) ->
            # Item not found in catalogue — treat as unassigned
            enriched = build_enriched_line(line, on_hand, shortfall, nil)
            {assigned_acc, unassigned_acc ++ [enriched]}

          true ->
            suppliers = resolve_suppliers(item)

            case suppliers do
              [supplier] ->
                # Exactly 1 supplier — assign
                enriched = build_enriched_line(line, on_hand, shortfall, item)
                supplier_uuid = supplier.uuid
                updated = Map.update(assigned_acc, supplier_uuid, [enriched], &(&1 ++ [enriched]))
                {updated, unassigned_acc}

              _ ->
                # 0 or >1 suppliers — unassigned bucket
                enriched = build_enriched_line(line, on_hand, shortfall, item)
                {assigned_acc, unassigned_acc ++ [enriched]}
            end
        end
      end)

    multi =
      assigned_by_supplier
      |> Enum.reduce(Ecto.Multi.new(), fn {supplier_uuid, lines}, multi ->
        op_name = {:create_supplier_order, supplier_uuid}

        Ecto.Multi.run(multi, op_name, fn repo, _changes ->
          %SupplierOrder{}
          |> SupplierOrder.changeset(%{
            supplier_uuid: supplier_uuid,
            internal_order_uuid: internal_order.uuid,
            location_uuid: location_uuid,
            lines: lines
          })
          |> Ecto.Changeset.put_change(:created_by_uuid, actor_uuid)
          |> Ecto.Changeset.put_change(:inserted_at, now)
          |> Ecto.Changeset.put_change(:updated_at, now)
          |> repo.insert()
        end)
      end)

    case repo().transaction(multi) do
      {:ok, results} ->
        supplier_orders =
          results
          |> Enum.filter(fn {key, _} -> match?({:create_supplier_order, _}, key) end)
          |> Enum.map(fn {_, order} -> order end)

        {:ok, %{supplier_orders: supplier_orders, unassigned_lines: unassigned_lines}}

      {:error, _op, reason, _changes} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Import from internal orders
  # ---------------------------------------------------------------------------

  @doc """
  Imports lines from one or more posted internal orders into an existing draft
  supplier order, filtering to items whose resolved supplier matches
  `supplier_order.supplier_uuid`.

  Steps:
  1. Loads each selected IO (must be posted and non-deleted).
  2. Enriches lines using the same stock + catalogue helpers as
     `generate_from_internal_order/2`.
  3. Filters to items whose single resolved supplier == supplier_order.supplier_uuid.
  4. Merges new lines with existing ones by item_uuid, summing
     required/shortfall/ordered quantities.
  5. Appends `source_refs` entries of type `"internal_order"` for each IO.
  6. Sets `internal_order_uuid` to the first selected IO (primary back-compat).
  7. Saves via `update_draft/2`.

  Returns:
  - `{:ok, updated_order}` on success.
  - `{:error, :no_supplier}` when `supplier_order.supplier_uuid` is nil.
  - `{:error, :not_draft}` when the order is not a draft.
  - `{:error, reason}` on DB failure.
  """
  def import_from_internal_orders(%SupplierOrder{supplier_uuid: nil}, _io_uuids, _actor_uuid) do
    {:error, :no_supplier}
  end

  def import_from_internal_orders(
        %SupplierOrder{status: status},
        _io_uuids,
        _actor_uuid
      )
      when status != "draft" do
    {:error, :not_draft}
  end

  def import_from_internal_orders(%SupplierOrder{} = supplier_order, io_uuids, _actor_uuid)
      when is_list(io_uuids) do
    internal_orders = load_posted_internal_orders(io_uuids)

    # Collect all item_uuids across all IOs
    all_item_uuids =
      internal_orders
      |> Enum.flat_map(fn io -> Enum.map(io.lines, & &1["item_uuid"]) end)
      |> Enum.filter(& &1)
      |> Enum.uniq()

    ctx = %{
      stock_map_by_location: build_stock_map_by_location(internal_orders, all_item_uuids),
      items_by_uuid: load_items_by_uuid(all_item_uuids),
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

    merged_refs =
      Enum.reduce(internal_orders, supplier_order.source_refs || [], fn io, acc_refs ->
        lines_map = Map.get(io_contributions, io.uuid, %{})
        CommittedQuantities.merge_ref(acc_refs, "internal_order", io.uuid, lines_map)
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

    update_draft(supplier_order, attrs)
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
         not sole_supplier?(item, ctx.target_supplier_uuid) do
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

  # An item is imported only when it resolves to exactly one supplier and that
  # supplier is this order's — an ambiguous item is left for a human to place.
  defp sole_supplier?(item, target_supplier_uuid) do
    match?([%{uuid: ^target_supplier_uuid}], resolve_suppliers(item))
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
    %{
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

  defp lock_status_step(uuid, expected_status, error) do
    Ecto.Multi.run(Ecto.Multi.new(), :lock_status, fn repo, _changes ->
      query =
        from(o in SupplierOrder,
          where: o.uuid == ^uuid and o.status == ^expected_status,
          lock: "FOR UPDATE"
        )

      case repo.one(query) do
        nil -> {:error, error}
        %SupplierOrder{} = locked -> {:ok, locked}
      end
    end)
  end

  # Resolves the list of linked suppliers for an item's manufacturer.
  # Returns [] when item has no manufacturer_uuid.
  #
  # An explicit primary supplier on the item is meant to always win — it's
  # how we'd resolve generic/unbranded materials that have no manufacturer
  # to mediate through, and how we'd break ties when a manufacturer has
  # more than one linked supplier. In practice neither mechanism below is
  # live yet: `phoenix_kit_catalogue` 0.10.0 (the latest published on Hex,
  # and what this repo's mix.lock pins) defines neither the
  # `primary_supplier_uuid` scalar (verified absent from
  # `deps/phoenix_kit_catalogue/lib/phoenix_kit_catalogue/schemas/item.ex`)
  # nor `Suppliers.primary_for_item/1` (verified absent from
  # `deps/phoenix_kit_catalogue/lib/phoenix_kit_catalogue/catalogue/
  # suppliers.ex`) — both landed only in catalogue's unreleased
  # `feature/parties-supplier-info` branch (merged to catalogue's `main`
  # 2026-07-15, not yet Hex-published). Until catalogue cuts that release
  # and this repo's `mix.lock` picks it up, both clauses below are dead and
  # every item resolves purely via `resolve_via_manufacturer/1` — including
  # the generic/unbranded and tie-break cases this comment describes.
  defp resolve_suppliers(%{primary_supplier_uuid: primary_supplier_uuid})
       when not is_nil(primary_supplier_uuid) do
    case Catalogue.get_supplier(primary_supplier_uuid) do
      nil -> []
      supplier -> [supplier]
    end
  end

  # Junction-primary path: once catalogue publishes the release carrying
  # `Suppliers.primary_for_item/1` (see the note above) and this repo's
  # `mix.lock` is bumped to it, this clause becomes the working
  # default-supplier mechanism (a V151 junction `is_primary` row) — no code
  # change needed here, the guard below activates automatically.
  #
  # `Code.ensure_loaded?/1` is required before `function_exported?/3`: in a
  # release the Suppliers module loads lazily and nothing else on this path
  # references it — a bare guard would silently disable junction resolution
  # after a cold boot (same convention as the Activity/Comments soft-deps).
  #
  # A primary row whose supplier is not locally resolvable (a CRM source
  # before the CRM release, or a deleted local supplier) falls through to
  # manufacturer resolution with a warning, symmetric with the no-primary
  # case.
  defp resolve_suppliers(%{uuid: item_uuid} = item) when not is_nil(item_uuid) do
    suppliers_mod = PhoenixKitCatalogue.Catalogue.Suppliers

    with true <-
           Code.ensure_loaded?(suppliers_mod) and
             function_exported?(suppliers_mod, :primary_for_item, 1),
         # credo:disable-for-next-line Credo.Check.Refactor.Apply
         %{supplier_uuid: supplier_uuid} <- apply(suppliers_mod, :primary_for_item, [item_uuid]) do
      case Catalogue.get_supplier(supplier_uuid) do
        nil ->
          Logger.warning(
            "warehouse: primary supplier #{supplier_uuid} for item #{item_uuid} " <>
              "is not locally resolvable (CRM source or deleted supplier); " <>
              "falling back to manufacturer resolution"
          )

          resolve_via_manufacturer(item)

        supplier ->
          [supplier]
      end
    else
      _ -> resolve_via_manufacturer(item)
    end
  end

  defp resolve_suppliers(item), do: resolve_via_manufacturer(item)

  defp resolve_via_manufacturer(%{manufacturer_uuid: nil}), do: []

  defp resolve_via_manufacturer(%{manufacturer_uuid: manufacturer_uuid}) do
    Catalogue.list_suppliers_for_manufacturer(manufacturer_uuid)
  end

  defp resolve_via_manufacturer(_item), do: []

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

    %{
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
  end
end
