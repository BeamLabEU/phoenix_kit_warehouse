defmodule PhoenixKitWarehouse.GoodsIssues do
  @moduledoc """
  Context for managing goods issues (materials written off to production).

  A goods issue registers materials leaving the warehouse into production.
  It DECREASES warehouse stock when posted. There is NO repost —
  posting a goods issue is a conditional decrement operation. If any line has
  insufficient stock the ENTIRE Multi rolls back. Correction after posting is
  limited to note and storage_folder only.
  """

  import Ecto.Query

  alias PhoenixKitWarehouse.CommittedQuantities
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.SourceKinds
  alias PhoenixKitWarehouse.StockLedger

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Lists non-deleted goods issues ordered by number descending (newest first).
  """
  def list_goods_issues(_opts \\ []) do
    GoodsIssue
    |> where([i], is_nil(i.deleted_at))
    |> order_by([i], desc: i.number)
    |> repo().all()
  end

  @doc "Returns the goods issue or raises."
  def get_goods_issue!(uuid), do: repo().get!(GoodsIssue, uuid)

  @doc "Returns `{:ok, issue}` or `{:error, :not_found}`."
  def get_goods_issue(uuid) do
    case repo().get(GoodsIssue, uuid) do
      nil -> {:error, :not_found}
      issue -> {:ok, issue}
    end
  end

  # ---------------------------------------------------------------------------
  # Draft CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new draft goods issue.

  `location_uuid` defaults to the configured default warehouse when not given.
  `created_by_uuid` is set programmatically — not via cast.
  """
  def create_goods_issue(attrs) do
    location_uuid =
      Map.get(attrs, :location_uuid) || Map.get(attrs, "location_uuid") ||
        StockLedger.default_location_uuid()

    attrs = Map.put(attrs, :location_uuid, location_uuid)
    created_by_uuid = Map.get(attrs, :created_by_uuid) || Map.get(attrs, "created_by_uuid")

    %GoodsIssue{}
    |> GoodsIssue.changeset(attrs)
    |> Ecto.Changeset.put_change(:created_by_uuid, created_by_uuid)
    |> repo().insert()
  end

  @doc """
  Imports lines from one or more posted internal orders into an existing draft
  goods issue.

  Lines are merged by `item_uuid` (quantities summed). The primary internal
  order is taken as the first UUID in `io_uuids`; its own UUID is set on the
  goods issue when it currently has no `internal_order_uuid` set. Source
  references (`source_refs`) are enriched with the traceability chain — each
  selected internal order plus the customer order(s)/sub-order(s) that fed it
  (from its own `source_refs`) — deduplicating by `{type, uuid}`.

  `issued_quantity` is set to `required_quantity` (same as `create_from_internal_order/2`).
  `unit_value` is left nil.

  Returns `{:ok, updated_issue}` or `{:error, reason}`.
  """
  def import_from_internal_orders(
        %GoodsIssue{status: "draft"} = issue,
        io_uuids,
        _actor_uuid
      )
      when is_list(io_uuids) and io_uuids != [] do
    orders = load_posted_internal_orders(io_uuids)

    if orders == [] do
      {:error, :no_valid_orders}
    else
      committed =
        CommittedQuantities.compute(
          GoodsIssue,
          ["internal_order"],
          Enum.map(orders, & &1.uuid),
          "issued_quantity"
        )

      remaining_by_io =
        Map.new(orders, fn io ->
          {io.uuid, remaining_lines_for_io(io, Map.get(committed, io.uuid, %{}))}
        end)

      merged_lines = merge_lines_from_orders(issue.lines, orders, remaining_by_io)

      primary = hd(orders)

      internal_order_uuid =
        if is_nil(issue.internal_order_uuid), do: primary.uuid, else: issue.internal_order_uuid

      top_refs = derive_top_refs(orders)

      source_refs_with_top =
        (issue.source_refs ++ top_refs)
        |> Enum.uniq_by(&{&1["type"], &1["uuid"]})

      updated_refs =
        Enum.reduce(orders, source_refs_with_top, fn io, acc_refs ->
          CommittedQuantities.merge_ref(
            acc_refs,
            "internal_order",
            io.uuid,
            Map.get(remaining_by_io, io.uuid, %{})
          )
        end)

      attrs = %{
        lines: merged_lines,
        internal_order_uuid: internal_order_uuid,
        source_refs: updated_refs
      }

      update_draft(issue, attrs)
    end
  end

  def import_from_internal_orders(%GoodsIssue{status: "draft"}, [], _actor_uuid) do
    {:error, :no_valid_orders}
  end

  def import_from_internal_orders(%GoodsIssue{}, _io_uuids, _actor_uuid) do
    {:error, :not_draft}
  end

  # ---------------------------------------------------------------------------
  # Private helpers for import
  # ---------------------------------------------------------------------------

  defp load_posted_internal_orders(uuids) do
    alias PhoenixKitWarehouse.InternalOrder

    uuids = Enum.filter(uuids, & &1)

    InternalOrder
    |> where([o], o.uuid in ^uuids and o.status == "posted" and is_nil(o.deleted_at))
    |> repo().all()
    |> Enum.sort_by(&Enum.find_index(uuids, fn u -> u == &1.uuid end))
  end

  # Customer order(s)/sub-order(s) that fed the given internal orders (from their
  # own source_refs) — purely informational chain display, not quantity-bearing.
  defp derive_top_refs(internal_orders) do
    internal_orders
    |> Enum.flat_map(fn io -> io.source_refs || [] end)
    |> Enum.filter(&(&1["type"] in ["order", "sub_order"]))
    |> Enum.uniq_by(&{&1["type"], &1["uuid"]})
  end

  # %{item_uuid => Decimal} of what's still outstanding for this IO after
  # netting out quantity already committed to other (or this) goods issue(s).
  defp remaining_lines_for_io(io, committed_for_io) do
    io.lines
    |> Enum.uniq_by(& &1["item_uuid"])
    |> Map.new(fn line ->
      item_uuid = line["item_uuid"]
      required = StockLedger.to_decimal(line["required_quantity"])
      already = Map.get(committed_for_io, item_uuid, Decimal.new("0"))
      remaining = Decimal.max(Decimal.new("0"), Decimal.sub(required, already))
      {item_uuid, remaining}
    end)
  end

  defp merge_lines_from_orders(existing_lines, orders, remaining_by_io) do
    new_lines =
      orders
      |> Enum.flat_map(fn order ->
        remaining = Map.get(remaining_by_io, order.uuid, %{})

        order.lines
        |> Enum.uniq_by(& &1["item_uuid"])
        |> Enum.map(fn line ->
          item_uuid = line["item_uuid"]

          %{
            "item_uuid" => item_uuid,
            "name" => line["name"],
            "sku" => line["sku"],
            "unit" => line["unit"],
            "catalogue_uuid" => line["catalogue_uuid"],
            "issued_quantity" => Map.get(remaining, item_uuid, Decimal.new("0")),
            "unit_value" => nil
          }
        end)
        |> Enum.reject(&Decimal.equal?(&1["issued_quantity"], Decimal.new("0")))
      end)

    Enum.reduce(new_lines, existing_lines, fn new_line, acc ->
      item_uuid = new_line["item_uuid"]
      existing_idx = Enum.find_index(acc, &(&1["item_uuid"] == item_uuid))

      if existing_idx do
        List.update_at(acc, existing_idx, fn existing ->
          existing_qty = StockLedger.to_decimal(existing["issued_quantity"])
          new_qty = StockLedger.to_decimal(new_line["issued_quantity"])
          Map.put(existing, "issued_quantity", Decimal.add(existing_qty, new_qty))
        end)
      else
        acc ++ [new_line]
      end
    end)
  end

  @doc """
  Creates a draft goods issue from a posted internal order.

  Lines are copied from the internal order with:
  - `issued_quantity` defaulting to the internal order line's `required_quantity`
    (the keeper adjusts down if fewer are actually available/needed).

  Sets `internal_order_uuid`, `location_uuid`, and propagates `source_refs`
  (the internal order's own registered-kind refs plus an `"internal_order"` ref
  for the source itself) so traceability is preserved.
  """
  def create_from_internal_order(internal_order, actor_uuid) do
    lines =
      internal_order.lines
      |> Enum.uniq_by(& &1["item_uuid"])
      |> Enum.map(fn line ->
        %{
          "item_uuid" => line["item_uuid"],
          "name" => line["name"],
          "sku" => line["sku"],
          "unit" => line["unit"],
          "catalogue_uuid" => line["catalogue_uuid"],
          "issued_quantity" => line["required_quantity"] || Decimal.new("0"),
          "unit_value" => nil
        }
      end)

    source_refs =
      ([%{"type" => "internal_order", "uuid" => internal_order.uuid}] ++
         Enum.filter(internal_order.source_refs || [], &registered_kind?(&1["type"])))
      |> Enum.uniq_by(&{&1["type"], &1["uuid"]})

    attrs = %{
      internal_order_uuid: internal_order.uuid,
      location_uuid: internal_order.location_uuid || StockLedger.default_location_uuid(),
      lines: lines,
      source_refs: source_refs
    }

    %GoodsIssue{}
    |> GoodsIssue.changeset(attrs)
    |> Ecto.Changeset.put_change(:created_by_uuid, actor_uuid)
    |> repo().insert()
  end

  @doc """
  Updates a draft goods issue. Returns `{:error, :not_draft}` when not in
  draft status.
  """
  def update_draft(%GoodsIssue{status: "draft"} = issue, attrs) do
    issue
    |> GoodsIssue.changeset(attrs)
    |> repo().update()
  end

  def update_draft(%GoodsIssue{}, _attrs), do: {:error, :not_draft}

  @doc """
  Manually attaches a traceability reference to a goods issue.

  `"internal_order"` is always valid (intra-module). Any other `type` must be
  a kind registered via `PhoenixKitWarehouse.SourceKinds`.
  Pure metadata — does not touch `lines` and is not gated to draft status.
  A duplicate `{type, uuid}` pair is a no-op.
  """
  def add_source_ref(%GoodsIssue{} = issue, type, uuid) do
    if valid_ref_type?(type) do
      new_ref = %{"type" => type, "uuid" => uuid}

      refs =
        ((issue.source_refs || []) ++ [new_ref])
        |> Enum.uniq_by(&{&1["type"], &1["uuid"]})

      issue
      |> GoodsIssue.changeset(%{source_refs: refs})
      |> repo().update()
    else
      {:error, :invalid_ref_type}
    end
  end

  defp valid_ref_type?("internal_order"), do: true
  defp valid_ref_type?(type), do: registered_kind?(type)

  defp registered_kind?(type), do: type in Enum.map(SourceKinds.list_kinds(), & &1.kind)

  @doc """
  Detaches a traceability reference from a goods issue. No-op when the
  `{type, uuid}` pair isn't present.
  """
  def remove_source_ref(%GoodsIssue{} = issue, type, uuid) do
    refs = Enum.reject(issue.source_refs || [], &(&1["type"] == type and &1["uuid"] == uuid))

    issue
    |> GoodsIssue.changeset(%{source_refs: refs})
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Posting — DECREASES stock
  # ---------------------------------------------------------------------------

  @doc """
  Posts a goods issue in an `Ecto.Multi` transaction. DECREASES warehouse stock.

  - Locks the row FOR UPDATE and re-checks status == "draft" (prevents double-posting).
  - Deduplicates lines by item_uuid.
  - For each line with issued_quantity > 0:
    - Captures `previous_quantity` = current on-hand for audit.
    - Calls `StockLedger.issue_quantity/3` (conditional decrement — WHERE quantity >= qty).
    - If ANY line returns `{:error, {:insufficient_stock, _}}`, the WHOLE Multi
      rolls back: stock is unchanged and the document stays draft.
  - Lines with issued_quantity == 0 contribute no stock change.
  - Merges `previous_quantity` into the persisted lines (audit trail).
  - Flips status → "posted", sets posted_at and performed_by_uuid.

  Returns `{:error, :not_draft}` for non-draft issues.
  Returns `{:error, {:insufficient_stock, item_uuid}}` when any line cannot be
  fulfilled; the entire transaction is rolled back.
  """
  def post_goods_issue(%GoodsIssue{status: status}, _performed_by_uuid)
      when status != "draft" do
    {:error, :not_draft}
  end

  def post_goods_issue(%GoodsIssue{} = issue, performed_by_uuid) do
    multi =
      issue.uuid
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
      |> StockLedger.stock_for_items(repo)
      |> Map.new(&{&1.item_uuid, &1})

    case issue_lines(lines, stock_map, locked.location_uuid, repo) do
      {:ok, audited_lines} ->
        locked
        |> GoodsIssue.post_changeset(audited_lines, performed_by_uuid)
        |> repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_lines(lines, stock_map, location_uuid, repo) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      item_uuid = line["item_uuid"]
      issued_qty = StockLedger.to_decimal(line["issued_quantity"])

      prior = Map.get(stock_map, item_uuid)
      previous_quantity = if prior, do: prior.quantity, else: Decimal.new("0")
      audited_line = Map.put(line, "previous_quantity", previous_quantity)

      case maybe_issue(item_uuid, issued_qty, location_uuid, repo) do
        :skip -> {:cont, {:ok, acc ++ [audited_line]}}
        {:ok, _new_qty} -> {:cont, {:ok, acc ++ [audited_line]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_issue(item_uuid, issued_qty, location_uuid, repo) do
    if Decimal.equal?(issued_qty, Decimal.new("0")) do
      :skip
    else
      StockLedger.issue_quantity(item_uuid, issued_qty,
        location_uuid: location_uuid,
        repo: repo
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Soft delete
  # ---------------------------------------------------------------------------

  @doc "Soft-deletes a draft goods issue. Returns {:error, :not_draft} for posted documents."
  def soft_delete(%GoodsIssue{status: "draft"} = issue, actor_uuid) do
    issue
    |> GoodsIssue.soft_delete_changeset(%{
      deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      deleted_by_uuid: actor_uuid
    })
    |> repo().update()
  end

  def soft_delete(%GoodsIssue{}, _actor_uuid), do: {:error, :not_draft}

  # ---------------------------------------------------------------------------
  # Correction (note + storage_folder on posted)
  # ---------------------------------------------------------------------------

  @doc """
  Corrects the note and/or storage_folder_uuid of a goods issue without
  changing status or lines. Works on documents in any status.
  Lines are immutable once posted.
  """
  def correct_goods_issue(%GoodsIssue{} = issue, attrs) do
    issue
    |> GoodsIssue.correction_changeset(attrs)
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Storage folder
  # ---------------------------------------------------------------------------

  @doc """
  Sets the `storage_folder_uuid` on a goods issue.
  Works on documents in any status.
  """
  def set_storage_folder(%GoodsIssue{} = issue, storage_folder_uuid) do
    issue
    |> GoodsIssue.storage_changeset(%{storage_folder_uuid: storage_folder_uuid})
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp lock_status_step(uuid, expected_status, error) do
    Ecto.Multi.run(Ecto.Multi.new(), :lock_status, fn repo, _changes ->
      query =
        from(i in GoodsIssue,
          where: i.uuid == ^uuid and i.status == ^expected_status,
          lock: "FOR UPDATE"
        )

      case repo.one(query) do
        nil -> {:error, error}
        %GoodsIssue{} = locked -> {:ok, locked}
      end
    end)
  end
end
