defmodule PhoenixKitWarehouse.InternalOrders do
  @moduledoc """
  Context for managing internal orders (warehouse demand documents).

  Internal orders bridge sub-order material sheets and supplier orders.
  They do NOT affect stock — posting only flips status and sets timestamps.
  """

  import Ecto.Query

  alias PhoenixKitWarehouse.CommittedQuantities
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.SourceKinds
  alias PhoenixKitWarehouse.StockLedger

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Lists non-deleted internal orders ordered by number descending (newest first).
  """
  def list_internal_orders(_opts \\ []) do
    InternalOrder
    |> where([o], is_nil(o.deleted_at))
    |> order_by([o], desc: o.number)
    |> repo().all()
  end

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
  Updates a draft internal order. Returns `{:error, :not_draft}` when not in
  draft status.
  """
  def update_draft(%InternalOrder{status: "draft"} = order, attrs) do
    order
    |> InternalOrder.changeset(attrs)
    |> repo().update()
  end

  def update_draft(%InternalOrder{}, _attrs), do: {:error, :not_draft}

  @doc """
  Manually attaches a traceability reference to an internal order.

  `type` must be a kind registered via `PhoenixKitWarehouse.SourceKinds`.
  Pure metadata — does not touch `lines` and is not gated to draft status.
  A duplicate `{type, uuid}` pair is a no-op.
  """
  def add_source_ref(%InternalOrder{} = order, type, uuid) do
    if registered_kind?(type) do
      new_ref = %{"type" => type, "uuid" => uuid}

      refs =
        ((order.source_refs || []) ++ [new_ref])
        |> Enum.uniq_by(&{&1["type"], &1["uuid"]})

      order
      |> InternalOrder.changeset(%{source_refs: refs})
      |> repo().update()
    else
      {:error, :invalid_ref_type}
    end
  end

  defp registered_kind?(type), do: type in Enum.map(SourceKinds.list_kinds(), & &1.kind)

  @doc """
  Detaches a traceability reference from an internal order. No-op when the
  `{type, uuid}` pair isn't present.
  """
  def remove_source_ref(%InternalOrder{} = order, type, uuid) do
    refs = Enum.reject(order.source_refs || [], &(&1["type"] == type and &1["uuid"] == uuid))

    order
    |> InternalOrder.changeset(%{source_refs: refs})
    |> repo().update()
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

  Returns `{:error, :not_draft}` for non-draft orders.
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

  @doc "Soft-deletes a draft internal order. Returns {:error, :not_draft} for posted documents."
  def soft_delete_internal_order(%InternalOrder{status: "draft"} = order, actor_uuid) do
    order
    |> InternalOrder.soft_delete_changeset(%{
      deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      deleted_by_uuid: actor_uuid
    })
    |> repo().update()
  end

  def soft_delete_internal_order(%InternalOrder{}, _actor_uuid), do: {:error, :not_draft}

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
            Map.put(line, "required_quantity", Decimal.to_string(remaining, :normal))
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
              Map.put(existing_line, "required_quantity", Decimal.to_string(summed, :normal))
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

  defp parse_decimal(nil), do: Decimal.new(0)
  defp parse_decimal(""), do: Decimal.new(0)
  defp parse_decimal(%Decimal{} = d), do: d

  defp parse_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> Decimal.new(0)
    end
  end

  defp parse_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp parse_decimal(_), do: Decimal.new(0)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Locks the row FOR UPDATE and asserts it is still in `expected_status`.
  defp lock_status_step(uuid, expected_status, error) do
    Ecto.Multi.run(Ecto.Multi.new(), :lock_status, fn repo, _changes ->
      query =
        from(o in InternalOrder,
          where: o.uuid == ^uuid and o.status == ^expected_status,
          lock: "FOR UPDATE"
        )

      case repo.one(query) do
        nil -> {:error, error}
        %InternalOrder{} = locked -> {:ok, locked}
      end
    end)
  end
end
