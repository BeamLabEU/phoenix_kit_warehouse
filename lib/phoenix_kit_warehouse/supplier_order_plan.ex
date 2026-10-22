defmodule PhoenixKitWarehouse.SupplierOrderPlan do
  @moduledoc """
  The plan behind "generate supplier orders" of a posted internal order: who
  supplies each line and why, how much of it is still to order, and a
  fingerprint that tells whether a plan shown earlier still holds. It only
  reads; nothing here writes a document.

  ## Supplier of a line

  The candidates of an item are its current supplier links
  (`item_supplier_info`) and the suppliers of its manufacturer, each resolved
  to a local supplier row: a local uuid as it is, a CRM company to the local
  row that projects it (`crm_company_uuid`; of several, an active one, then
  the one the item already names directly, then the earliest). A reference
  that resolves to nothing, or to an inactive supplier, is no candidate but
  stays visible in `excluded`. Then, in order:

    1. `:primary` - the primary link resolves to an active supplier;
    2. `:single_candidate` - exactly one candidate (`reason_source` says
       whether it is the item's own link or the manufacturer's);
    3. `:ambiguous` - more than one candidate and no usable primary: a human
       picks, the plan never does;
    4. `:no_supplier` - no candidate (`primary_issue` says when a primary
       exists but is unresolved or inactive);
    5. `:no_item` - the item is not in the catalogue (or deleted).

  ## Quantity

  Per item (an item on several lines adds its demand up and covers the lines
  in their order):

      need     = required - issued
      to_order = max(0, need - on_hand - in_transit)

  `issued` is what posted, live goods issues gave out for this internal
  order, each issue counted once: the `"lines"` of its ref to the order, its
  own lines when the ref has none, its own lines when it has no ref to the
  order but `internal_order_uuid` names it. `on_hand` is the stock on the
  order's location (received goods are already in it). `in_transit` is what
  live supplier orders still bring for this order: an order of this one alone
  (`internal_order_uuid` names it and it refers to no other one) counts its
  lines while a draft and `ordered - received` once posted; a combined order
  counts its ref's `"lines"` while a draft and
  `min(ref lines, ordered - received)` once posted.

  ## Preselected supplier

  A line without an automatic supplier (`:ambiguous`, `:no_supplier`) whose
  item already lies in a live draft of this order that has an active
  supplier is `preselected` to that supplier: what is missing goes where the
  rest already is. Of several such drafts, the one `targets` would prefer -
  a draft of this order alone, then the highest number. It is a default
  choice, not an automatic supplier: the reason stays, a person may choose
  another supplier or "do not order", and without a choice `assemble/2`
  (and so a generation without the window) places the line there.

  ## Where the lines go

  One draft per (internal order, supplier): `targets` names, per supplier,
  the live draft that already belongs to this order - a draft of this order
  alone, else a combined draft that refers to it, of several the highest
  number. `assemble/2` puts a supplier's lines into that draft
  (`target_lines/2`), or into a new one when there is none.

  The catalogue is read through `PhoenixKitCatalogue.Catalogue` only, one
  call per distinct item and manufacturer.
  """

  import Ecto.Query

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.LineExplanation
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKitWarehouse.SupplierOrders

  @type reason :: :primary | :single_candidate | :ambiguous | :no_supplier | :no_item
  @type source :: :primary | :item_link | :manufacturer

  @type resolution :: %{
          reason: reason(),
          reason_source: source() | nil,
          primary_issue: :unresolved | :inactive | nil,
          supplier_uuid: Ecto.UUID.t() | nil,
          candidates: [%{uuid: Ecto.UUID.t(), name: String.t(), sources: [source()]}],
          excluded: [%{uuid: Ecto.UUID.t(), why: :unresolved | :inactive, sources: [source()]}]
        }

  @type plan :: %{
          internal_order: InternalOrder.t(),
          location_uuid: Ecto.UUID.t() | nil,
          lines: [map()],
          groups: [
            %{
              supplier_uuid: Ecto.UUID.t(),
              supplier_name: String.t(),
              target: map() | :new,
              keys: [String.t()]
            }
          ],
          supplier_orders: [map()],
          targets: %{Ecto.UUID.t() => map()},
          suppliers: [%{uuid: Ecto.UUID.t(), name: String.t()}],
          fingerprint: String.t()
        }

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp zero, do: Decimal.new("0")

  # ---------------------------------------------------------------------------
  # The plan
  # ---------------------------------------------------------------------------

  @doc """
  Builds the plan of a posted, live internal order. See the moduledoc for the
  rules. `opts` is reserved.

  Every line is `%{key, index, item_uuid, name, sku, unit, catalogue_uuid,
  base_price, explanation, reason, reason_source, primary_issue, candidates, excluded,
  auto_supplier_uuid, choosable?, choices, required, issued, need, on_hand,
  preselected, stock, in_transit, in_transit_from, to_order, zero_reason}`;
  `key` is `"<index>:<item_uuid>"`, `stock` the raw quantity on the location
  and `on_hand`/`in_transit`/`issued` the share of it this line uses. A line
  is `choosable?` when its item exists and something is to order; `choices`
  then lists its candidates followed by every other active supplier.
  `preselected` is `%{supplier_uuid, uuid, number}` of the draft a line
  without an automatic supplier is preselected from, else `nil` (see the
  moduledoc and `default_supplier_uuid/1`). `zero_reason` says why nothing
  is to order (`:issued`, `:on_hand`, `:in_transit`, `:no_need`).
  `supplier_orders` summarises the live supplier orders of the order (with
  their `lines` and `source_refs`), `targets` maps a supplier to the one of
  them its lines are appended to.
  """
  @spec build(Ecto.UUID.t() | term(), keyword()) ::
          {:ok, plan()} | {:error, :not_found | :not_posted | :deleted}
  def build(internal_order_uuid, _opts \\ []) do
    with {:ok, io} <- load_internal_order(internal_order_uuid) do
      {:ok, build_for(io)}
    end
  end

  # The checks of `build/2`; the writing side calls it under its lock.
  @doc false
  @spec load_internal_order(term()) ::
          {:ok, InternalOrder.t()} | {:error, :not_found | :not_posted | :deleted}
  def load_internal_order(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %InternalOrder{} = io <- repo().get(InternalOrder, uuid) do
      cond do
        io.deleted_at != nil -> {:error, :deleted}
        io.status != "posted" -> {:error, :not_posted}
        true -> {:ok, io}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  # Builds the plan of `io` as given, without the checks of `build/2` (so a
  # test can see what the fingerprint holds of the internal order itself).
  # `:supplier_orders` - the live supplier orders of the order as the caller
  # has locked them (the writing side), instead of reading them here.
  @doc false
  @spec build_for(InternalOrder.t(), keyword()) :: plan()
  def build_for(%InternalOrder{} = io, opts \\ []) do
    io_lines = io.lines || []
    location_uuid = io.location_uuid || StockLedger.default_location_uuid()

    item_uuids =
      io_lines |> Enum.map(& &1["item_uuid"]) |> Enum.filter(&is_binary/1) |> Enum.uniq()

    items_by_uuid = load_items(item_uuids)
    ctx = catalogue_context(Map.values(items_by_uuid))

    supplier_orders =
      case Keyword.fetch(opts, :supplier_orders) do
        {:ok, locked} ->
          Enum.sort_by(locked, & &1.number)

        :error ->
          io.uuid |> live_supplier_orders_query() |> order_by([o], asc: o.number) |> repo().all()
      end

    totals = %{
      stock: stock_by_item(item_uuids, location_uuid),
      issued: issued_for(io.uuid),
      in_transit: in_transit_for(io.uuid, supplier_orders)
    }

    active = active_suppliers(ctx)

    lines =
      io_lines
      |> Enum.with_index()
      |> allocate(totals)
      |> Enum.map(fn {line, index, quantities} ->
        item = Map.get(items_by_uuid, line["item_uuid"])

        line
        |> build_line(index, quantities, resolve_line_supplier(item, ctx), active)
        |> Map.put(:base_price, item && StockLedger.to_decimal_or_nil(item.base_price))
      end)

    summaries = Enum.map(supplier_orders, &order_summary(&1, io.uuid))
    targets = targets(summaries)

    plan = %{
      internal_order: io,
      location_uuid: location_uuid,
      lines: lines,
      groups: groups(lines, ctx, targets),
      supplier_orders: summaries,
      targets: targets,
      suppliers: Enum.map(active, &%{uuid: &1.uuid, name: &1.name})
    }

    Map.put(plan, :fingerprint, fingerprint(plan, supplier_orders, ctx))
  end

  defp load_items([]), do: %{}

  defp load_items(item_uuids) do
    item_uuids |> Catalogue.list_items_by_uuids() |> Map.new(&{&1.uuid, &1})
  end

  defp build_line(line, index, quantities, resolution, active) do
    choosable? = resolution.reason != :no_item and Decimal.gt?(quantities.to_order, 0)

    choices =
      if choosable? do
        Enum.uniq(Enum.map(resolution.candidates, & &1.uuid) ++ Enum.map(active, & &1.uuid))
      else
        []
      end

    Map.merge(quantities, %{
      preselected: preselected(resolution, quantities.in_transit_from, choices),
      key: "#{index}:#{line["item_uuid"]}",
      index: index,
      item_uuid: line["item_uuid"],
      name: line["name"],
      sku: line["sku"],
      unit: line["unit"],
      catalogue_uuid: line["catalogue_uuid"],
      explanation: LineExplanation.get(line),
      reason: resolution.reason,
      reason_source: resolution.reason_source,
      primary_issue: resolution.primary_issue,
      candidates: resolution.candidates,
      excluded: resolution.excluded,
      auto_supplier_uuid: resolution.supplier_uuid,
      choosable?: choosable?,
      choices: choices
    })
  end

  # A line without an automatic supplier, with something to order, whose
  # item lies in live drafts of this order with an active supplier: the one
  # `targets/1` would prefer. The reason names the draft the item lies in;
  # the lines are still appended to the supplier's target, which can be
  # another draft (a draft of this order alone beats a combined one), the
  # same as for a line with an automatic supplier.
  defp preselected(%{supplier_uuid: nil}, in_transit_from, choices) do
    case Enum.filter(in_transit_from, &(&1.status == "draft" and &1.supplier_uuid in choices)) do
      [] ->
        nil

      drafts ->
        drafts
        |> Enum.max_by(&{&1.single_source?, &1.number})
        |> Map.take([:supplier_uuid, :uuid, :number])
    end
  end

  defp preselected(_automatic, _in_transit_from, _choices), do: nil

  @doc """
  The supplier a plan line gets without a choice: its automatic supplier,
  else the supplier it is preselected to, else `nil`.
  """
  @spec default_supplier_uuid(map()) :: Ecto.UUID.t() | nil
  def default_supplier_uuid(%{auto_supplier_uuid: uuid}) when is_binary(uuid), do: uuid
  def default_supplier_uuid(%{preselected: %{supplier_uuid: uuid}}), do: uuid
  def default_supplier_uuid(_line), do: nil

  # Lines with something to order and a supplier without a choice, grouped by
  # that supplier in the order the suppliers first appear, each with the
  # draft a generation writes into (`:new` when there is none).
  defp groups(lines, ctx, targets) do
    lines
    |> Enum.filter(&(default_supplier_uuid(&1) && Decimal.gt?(&1.to_order, 0)))
    |> Enum.group_by(&default_supplier_uuid/1)
    |> Enum.map(fn {supplier_uuid, [first | _] = grouped} ->
      {first.index,
       %{
         supplier_uuid: supplier_uuid,
         supplier_name: supplier_name(ctx, supplier_uuid),
         target: Map.get(targets, supplier_uuid, :new),
         keys: Enum.map(grouped, & &1.key)
       }}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp supplier_name(ctx, uuid) do
    case Map.get(ctx.suppliers, uuid) do
      nil -> nil
      supplier -> supplier.name
    end
  end

  defp order_summary(%SupplierOrder{} = order, io_uuid) do
    %{
      uuid: order.uuid,
      number: order.number,
      status: order.status,
      supplier_uuid: order.supplier_uuid,
      single_source?: SupplierOrders.single_source?(order, io_uuid),
      refers?: io_ref(order.source_refs, io_uuid) != nil,
      updated_at: order.updated_at,
      lines: order.lines || [],
      source_refs: order.source_refs || []
    }
  end

  # The draft of each supplier that a generation writes into: a draft of this
  # order alone, else a combined draft that refers to it; of several, the one
  # with the highest number. Posted orders and drafts without a supplier are
  # never one.
  defp targets(summaries) do
    summaries
    |> Enum.filter(
      &(&1.status == "draft" and is_binary(&1.supplier_uuid) and (&1.single_source? or &1.refers?))
    )
    |> Enum.group_by(& &1.supplier_uuid)
    |> Map.new(fn {supplier_uuid, drafts} ->
      {supplier_uuid, Enum.max_by(drafts, &{&1.single_source?, &1.number})}
    end)
  end

  # Active local suppliers by name: what a line may be given by hand.
  defp active_suppliers(ctx) do
    ctx.suppliers
    |> Map.values()
    |> Enum.filter(&active?/1)
    |> Enum.sort_by(&{&1.name, &1.uuid})
  end

  defp active?(supplier), do: supplier.status == "active"

  # ---------------------------------------------------------------------------
  # Supplier of a line
  # ---------------------------------------------------------------------------

  @doc """
  Reads what `resolve_line_supplier/2` needs for `items` from the catalogue:
  every local supplier once, the current supplier links of each distinct item
  and the supplier links of each distinct manufacturer.
  """
  @spec catalogue_context([struct()]) :: map()
  def catalogue_context(items) do
    suppliers = Catalogue.list_suppliers()

    manufacturer_uuids =
      items |> Enum.map(&Map.get(&1, :manufacturer_uuid)) |> Enum.filter(& &1) |> Enum.uniq()

    %{
      suppliers: Map.new(suppliers, &{&1.uuid, &1}),
      projections:
        Enum.group_by(Enum.filter(suppliers, & &1.crm_company_uuid), & &1.crm_company_uuid),
      infos:
        items
        |> Enum.map(& &1.uuid)
        |> Enum.uniq()
        |> Map.new(&{&1, Catalogue.list_supplier_infos_for_item(&1)}),
      manufacturer_links: Map.new(manufacturer_uuids, &{&1, Catalogue.linked_supplier_uuids(&1)})
    }
  end

  @doc """
  The supplier of a line with `item` (`nil` when the item is not in the
  catalogue), by the rules of the moduledoc. `ctx` is
  `catalogue_context/1` of a list that holds the item.
  """
  @spec resolve_line_supplier(struct() | nil, map()) :: resolution()
  def resolve_line_supplier(nil, _ctx) do
    %{
      reason: :no_item,
      reason_source: nil,
      primary_issue: nil,
      supplier_uuid: nil,
      candidates: [],
      excluded: []
    }
  end

  def resolve_line_supplier(item, ctx) do
    refs = supplier_refs(item, ctx)
    direct = MapSet.new(for {uuid, _source} <- refs, Map.has_key?(ctx.suppliers, uuid), do: uuid)

    resolved =
      Enum.map(refs, fn {uuid, source} -> {uuid, source, resolve_ref(uuid, ctx, direct)} end)

    candidates =
      for({_uuid, source, {:ok, s}} <- resolved, active?(s), do: {s, source})
      |> collect(fn {s, _} -> s.uuid end, fn {s, _}, sources ->
        %{uuid: s.uuid, name: s.name, sources: sources}
      end)

    excluded =
      resolved
      |> Enum.flat_map(fn
        {uuid, source, :unresolved} -> [{uuid, :unresolved, source}]
        {_uuid, source, {:ok, s}} -> if active?(s), do: [], else: [{s.uuid, :inactive, source}]
      end)
      |> Enum.map(fn {uuid, why, source} -> {{uuid, why}, source} end)
      |> collect(&elem(&1, 0), fn {{uuid, why}, _}, sources ->
        %{uuid: uuid, why: why, sources: sources}
      end)

    primary = Enum.find(resolved, &match?({_, :primary, _}, &1))
    pick(primary, candidates, excluded)
  end

  # Primary link first, then the item's other current links in their catalogue
  # order, then the manufacturer's suppliers.
  defp supplier_refs(item, ctx) do
    infos = Map.get(ctx.infos, item.uuid, [])

    primary = for %{is_primary: true} = info <- infos, do: {info.supplier_uuid, :primary}
    linked = for info <- infos, info.is_primary != true, do: {info.supplier_uuid, :item_link}

    manufacturer =
      for uuid <- Map.get(ctx.manufacturer_links, Map.get(item, :manufacturer_uuid), []),
          do: {uuid, :manufacturer}

    primary ++ linked ++ manufacturer
  end

  defp resolve_ref(uuid, ctx, direct) do
    case Map.get(ctx.suppliers, uuid) do
      nil -> projection(Map.get(ctx.projections, uuid, []), direct)
      supplier -> {:ok, supplier}
    end
  end

  defp projection([], _direct), do: :unresolved

  # Of several local rows projecting one company: an active one, then one the
  # item already names directly (so the company is not two candidates), then
  # the earliest. `false` sorts before `true`.
  defp projection(rows, direct) do
    {:ok,
     Enum.min_by(rows, fn s ->
       {not active?(s), not MapSet.member?(direct, s.uuid), DateTime.to_unix(s.inserted_at),
        s.uuid}
     end)}
  end

  # Groups `{thing, source}` pairs by `key_fun`, in first-appearance order,
  # with the distinct sources of each.
  defp collect(pairs, key_fun, build_fun) do
    pairs
    |> Enum.reduce({[], %{}}, fn {_, source} = pair, {order, acc} ->
      key = key_fun.(pair)

      case Map.fetch(acc, key) do
        {:ok, {first, sources}} -> {order, Map.put(acc, key, {first, sources ++ [source]})}
        :error -> {[key | order], Map.put(acc, key, {pair, [source]})}
      end
    end)
    |> then(fn {order, acc} ->
      order
      |> Enum.reverse()
      |> Enum.map(fn key ->
        {first, sources} = Map.fetch!(acc, key)
        build_fun.(first, Enum.uniq(sources))
      end)
    end)
  end

  defp pick({_uuid, :primary, {:ok, %{status: "active"} = s}}, candidates, excluded) do
    resolution(:primary, :primary, nil, s.uuid, candidates, excluded)
  end

  defp pick(primary, candidates, excluded) do
    issue = primary_issue(primary)

    case candidates do
      [] ->
        resolution(:no_supplier, nil, issue, nil, candidates, excluded)

      [%{uuid: uuid, sources: sources}] ->
        source = if :item_link in sources, do: :item_link, else: :manufacturer
        resolution(:single_candidate, source, issue, uuid, candidates, excluded)

      _ ->
        resolution(:ambiguous, nil, issue, nil, candidates, excluded)
    end
  end

  defp primary_issue(nil), do: nil
  defp primary_issue({_uuid, :primary, :unresolved}), do: :unresolved
  defp primary_issue({_uuid, :primary, {:ok, _inactive}}), do: :inactive

  defp resolution(reason, source, issue, supplier_uuid, candidates, excluded) do
    %{
      reason: reason,
      reason_source: source,
      primary_issue: issue,
      supplier_uuid: supplier_uuid,
      candidates: candidates,
      excluded: excluded
    }
  end

  # ---------------------------------------------------------------------------
  # Quantities
  # ---------------------------------------------------------------------------

  defp stock_by_item([], _location_uuid), do: %{}

  defp stock_by_item(item_uuids, location_uuid) do
    item_uuids
    |> StockLedger.stock_for_items_at_location(location_uuid)
    |> Map.new(&{&1.item_uuid, StockLedger.to_decimal(&1.quantity)})
  end

  # `%{item_uuid => Decimal}` given out by the posted, live goods issues of the
  # internal order, each issue counted once.
  defp issued_for(io_uuid) do
    from(g in GoodsIssue,
      where: g.status == "posted" and is_nil(g.deleted_at),
      where:
        g.internal_order_uuid == ^io_uuid or
          fragment("? @> ?::jsonb", g.source_refs, ^[ref_json(io_uuid)])
    )
    |> repo().all()
    |> Enum.map(fn issue ->
      case io_ref(issue.source_refs, io_uuid) do
        %{"lines" => lines} when is_map(lines) -> decimalize(lines)
        _ref_without_lines_or_none -> line_quantities(issue.lines, "issued_quantity")
      end
    end)
    |> sum_maps()
  end

  # The live supplier orders of the internal order: the ones that name it in
  # `internal_order_uuid` and the ones that refer to it. Unordered; the
  # writing side locks them in uuid order.
  @doc false
  @spec live_supplier_orders_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def live_supplier_orders_query(io_uuid) do
    from(o in SupplierOrder,
      where: is_nil(o.deleted_at),
      where:
        o.internal_order_uuid == ^io_uuid or
          fragment("? @> ?::jsonb", o.source_refs, ^[ref_json(io_uuid)])
    )
  end

  # `%{item_uuid => {Decimal, [%{uuid, number, status, supplier_uuid,
  # single_source?, quantity}]}}`.
  defp in_transit_for(io_uuid, orders) do
    posted_uuids = for %{status: "posted", uuid: uuid} <- orders, do: uuid

    received =
      if posted_uuids == [], do: %{}, else: SupplierOrders.received_summaries(posted_uuids)

    orders
    |> Enum.flat_map(fn order ->
      order
      |> order_in_transit(io_uuid, Map.get(received, order.uuid, %{}))
      |> Enum.filter(fn {_item, qty} -> Decimal.gt?(qty, 0) end)
      |> Enum.map(fn {item, qty} ->
        {item, qty,
         %{
           uuid: order.uuid,
           number: order.number,
           status: order.status,
           supplier_uuid: order.supplier_uuid,
           single_source?: SupplierOrders.single_source?(order, io_uuid),
           quantity: qty
         }}
      end)
    end)
    |> Enum.reduce(%{}, fn {item, qty, from}, acc ->
      Map.update(acc, item, {qty, [from]}, fn {total, froms} ->
        {Decimal.add(total, qty), froms ++ [from]}
      end)
    end)
  end

  defp order_in_transit(order, io_uuid, received) do
    single? = SupplierOrders.single_source?(order, io_uuid)
    ref = io_ref(order.source_refs, io_uuid)

    cond do
      single? and order.status == "draft" ->
        # Posting keeps the first line of an item, so that is what a draft brings.
        order.lines
        |> Enum.uniq_by(& &1["item_uuid"])
        |> line_quantities("ordered_quantity")

      single? ->
        order.lines
        |> line_quantities("ordered_quantity")
        |> Map.new(fn {item, ordered} -> {item, unreceived(ordered, received, item)} end)

      is_nil(ref) ->
        %{}

      order.status == "draft" ->
        ref_lines(ref, order)

      true ->
        ordered = line_quantities(order.lines, "ordered_quantity")

        ref
        |> ref_lines(order)
        |> Map.new(fn {item, share} ->
          rest = unreceived(Map.get(ordered, item, zero()), received, item)
          {item, Decimal.min(share, rest)}
        end)
    end
  end

  defp unreceived(ordered, received, item) do
    Decimal.max(zero(), Decimal.sub(ordered, Map.get(received, item, zero())))
  end

  # A ref without a `"lines"` breakdown stands for the whole document, as in
  # `PhoenixKitWarehouse.CommittedQuantities`.
  defp ref_lines(%{"lines" => lines}, _order) when is_map(lines), do: decimalize(lines)
  defp ref_lines(_ref, order), do: line_quantities(order.lines, "ordered_quantity")

  defp io_ref(refs, io_uuid) do
    Enum.find(List.wrap(refs), &match?(%{"type" => "internal_order", "uuid" => ^io_uuid}, &1))
  end

  defp ref_json(io_uuid), do: %{"type" => "internal_order", "uuid" => io_uuid}

  defp line_quantities(lines, field) do
    lines
    |> List.wrap()
    |> Enum.filter(&is_binary(&1["item_uuid"]))
    |> Enum.map(&%{&1["item_uuid"] => StockLedger.to_decimal(&1[field])})
    |> sum_maps()
  end

  defp decimalize(lines) do
    Map.new(lines, fn {item, qty} -> {item, StockLedger.to_decimal(qty)} end)
  end

  defp sum_maps(maps) do
    Enum.reduce(maps, %{}, fn map, acc ->
      Map.merge(acc, map, fn _item, a, b -> Decimal.add(a, b) end)
    end)
  end

  # Spreads the per-item totals over the lines of each item in line order:
  # issued first, then stock, then what is in transit.
  defp allocate(indexed_lines, totals) do
    pools =
      Map.new(indexed_lines, fn {line, _index} ->
        item = line["item_uuid"]
        {in_transit, _from} = Map.get(totals.in_transit, item, {zero(), []})

        {item,
         %{
           issued: Map.get(totals.issued, item, zero()),
           stock: Map.get(totals.stock, item, zero()),
           in_transit: in_transit
         }}
      end)

    {allocated, _pools} =
      Enum.map_reduce(indexed_lines, pools, fn {line, index}, pools ->
        item = line["item_uuid"]
        pool = Map.fetch!(pools, item)
        required = Decimal.max(zero(), StockLedger.to_decimal(line["required_quantity"]))

        issued = Decimal.min(pool.issued, required)
        need = Decimal.sub(required, issued)
        on_hand = Decimal.min(Decimal.max(pool.stock, zero()), need)
        in_transit = Decimal.min(pool.in_transit, Decimal.sub(need, on_hand))
        to_order = Decimal.sub(Decimal.sub(need, on_hand), in_transit)
        {_total, from} = Map.get(totals.in_transit, item, {zero(), []})

        quantities = %{
          required: required,
          issued: issued,
          need: need,
          on_hand: on_hand,
          stock: Map.get(totals.stock, item, zero()),
          in_transit: in_transit,
          in_transit_from: from,
          to_order: to_order,
          zero_reason: zero_reason(required, need, in_transit, to_order)
        }

        rest = %{
          issued: Decimal.sub(pool.issued, issued),
          stock: Decimal.sub(pool.stock, on_hand),
          in_transit: Decimal.sub(pool.in_transit, in_transit)
        }

        {{line, index, quantities}, Map.put(pools, item, rest)}
      end)

    allocated
  end

  defp zero_reason(required, need, in_transit, to_order) do
    cond do
      Decimal.gt?(to_order, 0) -> nil
      Decimal.eq?(required, 0) -> :no_need
      Decimal.eq?(need, 0) -> :issued
      Decimal.gt?(in_transit, 0) -> :in_transit
      true -> :on_hand
    end
  end

  # ---------------------------------------------------------------------------
  # Fingerprint
  # ---------------------------------------------------------------------------

  # sha256 of everything the plan decides on, in a canonical term of lists
  # and tuples only: the internal order (not its updated_at - a posted order's
  # lines cannot change, a note must not make a plan stale), the location, the
  # lines, the live supplier orders with a hash of their lines and refs, and
  # the active suppliers (a deactivated one is a stale plan, not a refused
  # choice) and the draft each supplier's lines are written into.
  defp fingerprint(plan, supplier_orders, ctx) do
    io = plan.internal_order

    canon = {
      :supplier_order_plan_v1,
      {io.uuid, canon(io.deleted_at), io.status},
      plan.location_uuid,
      Enum.map(plan.lines, &line_canon/1),
      supplier_orders
      |> Enum.sort_by(& &1.uuid)
      |> Enum.map(fn o ->
        {o.uuid, o.status, o.supplier_uuid, canon(o.updated_at), hash(canon(o.lines)),
         hash(canon(o.source_refs))}
      end),
      ctx.suppliers
      |> Map.values()
      |> Enum.filter(&active?/1)
      |> Enum.map(&{&1.uuid, &1.status})
      |> Enum.sort(),
      plan.targets
      |> Enum.map(fn {supplier, target} -> {supplier, target.uuid} end)
      |> Enum.sort()
    }

    canon |> hash() |> Base.encode16(case: :lower)
  end

  defp line_canon(line) do
    {line.key, line.item_uuid, canon(line.need), canon(line.issued), canon(line.on_hand),
     canon(line.in_transit), canon(line.to_order),
     line.candidates |> Enum.map(& &1.uuid) |> Enum.sort(), line.auto_supplier_uuid, line.reason,
     line.reason_source, line.primary_issue, line.preselected && line.preselected.uuid}
  end

  defp hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))

  defp canon(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string()
  defp canon(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp canon(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp canon(%Date{} = d), do: Date.to_iso8601(d)

  defp canon(map) when is_map(map),
    do: map |> Enum.map(fn {k, v} -> {canon(k), canon(v)} end) |> Enum.sort()

  defp canon(list) when is_list(list), do: Enum.map(list, &canon/1)
  defp canon(other), do: other

  # ---------------------------------------------------------------------------
  # Manual choices
  # ---------------------------------------------------------------------------

  @doc """
  Checks manual choices `%{key => supplier_uuid | "skip"}` against `plan`. A
  choice is allowed only for a `choosable?` line (its item exists and
  something is to order), and a supplier only from that line's `choices`.
  Returns `:ok` or `{:error, {:invalid_choice, key}}` for the first wrong key
  in key order.
  """
  @spec validate_choices(plan(), map()) :: :ok | {:error, {:invalid_choice, String.t()}}
  def validate_choices(%{lines: lines}, choices) when is_map(choices) do
    by_key = Map.new(lines, &{&1.key, &1})

    choices
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {key, choice} ->
      if valid_choice?(Map.get(by_key, key), choice),
        do: nil,
        else: {:error, {:invalid_choice, key}}
    end)
  end

  defp valid_choice?(%{choosable?: true}, "skip"), do: true

  defp valid_choice?(%{choosable?: true, choices: allowed}, choice) when is_binary(choice) do
    case Ecto.UUID.cast(choice) do
      {:ok, uuid} -> uuid in allowed
      :error -> false
    end
  end

  defp valid_choice?(_line, _choice), do: false

  # ---------------------------------------------------------------------------
  # What a plan writes
  # ---------------------------------------------------------------------------

  @doc """
  What writing `plan` with `choices` (`%{key => supplier_uuid | "skip"}`, as
  `validate_choices/2` accepts them) creates, without touching the database:

    * `orders` - one per supplier, in the order of their first line:
      `%{supplier_uuid, supplier_name, target, keys, lines}`; `target` is the
      draft of `plan.targets` the lines are appended to (`target_lines/2`)
      or `:new`, `lines` the supplier order lines (an item on several lines
      of the internal order is one line; `target_lines/2` gives the target's
      lines after the write);
    * `unplaced` - lines with something to order that get no supplier: the
      choice is "skip", or the line has no default supplier and no choice;
    * `not_ordered` - lines that cannot be chosen: nothing to order, or the
      item is not in the catalogue.

  A choice for a line that cannot be chosen, or one that is no uuid, is
  ignored; a choice for a line with an automatic or preselected supplier
  replaces it. Without a choice a line goes to `default_supplier_uuid/1`.
  """
  @spec assemble(plan(), map()) :: %{orders: [map()], unplaced: [map()], not_ordered: [map()]}
  def assemble(%{lines: lines} = plan, choices) when is_map(choices) do
    names = Map.new(plan.suppliers, &{&1.uuid, &1.name})

    {placed, unplaced, not_ordered} =
      Enum.reduce(lines, {[], [], []}, fn line, {placed, unplaced, not_ordered} ->
        case line_supplier(line, Map.get(choices, line.key)) do
          :not_ordered -> {placed, unplaced, [line | not_ordered]}
          nil -> {placed, [line | unplaced], not_ordered}
          supplier_uuid -> {[{supplier_uuid, line} | placed], unplaced, not_ordered}
        end
      end)

    orders =
      placed
      |> Enum.reverse()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort_by(fn {_supplier, [first | _]} -> first.index end)
      |> Enum.map(fn {supplier_uuid, supplier_lines} ->
        %{
          supplier_uuid: supplier_uuid,
          supplier_name: Map.get(names, supplier_uuid),
          target: Map.get(plan.targets, supplier_uuid, :new),
          keys: Enum.map(supplier_lines, & &1.key),
          lines: order_lines(supplier_lines)
        }
      end)

    %{orders: orders, unplaced: Enum.reverse(unplaced), not_ordered: Enum.reverse(not_ordered)}
  end

  @doc """
  The lines of an `assemble/2` result with something to order that are not
  ordered: the `unplaced` ones and the ones whose item is not in the
  catalogue, in line order. What a generation reports as unassigned and the
  preview window counts as "not ordered".
  """
  @spec unassigned(%{
          required(:unplaced) => [map()],
          required(:not_ordered) => [map()],
          optional(atom()) => any()
        }) :: [map()]
  def unassigned(%{unplaced: unplaced, not_ordered: not_ordered}) do
    missing = Enum.filter(not_ordered, &(&1.reason == :no_item and Decimal.gt?(&1.to_order, 0)))
    Enum.sort_by(unplaced ++ missing, & &1.index)
  end

  defp line_supplier(%{choosable?: false}, _choice), do: :not_ordered
  defp line_supplier(_line, "skip"), do: nil

  defp line_supplier(line, choice) when is_binary(choice) do
    case Ecto.UUID.cast(choice) do
      {:ok, uuid} -> uuid
      :error -> default_supplier_uuid(line)
    end
  end

  defp line_supplier(line, _no_choice), do: default_supplier_uuid(line)

  # One supplier order line per item, in the order of its first line; the
  # quantities of an item's lines add up, their explanations are merged.
  defp order_lines(plan_lines) do
    plan_lines
    |> Enum.group_by(& &1.item_uuid)
    |> Enum.sort_by(fn {_item, [first | _]} -> first.index end)
    |> Enum.map(fn {_item, [first | _] = same_item} ->
      Enum.reduce(tl(same_item), order_line(first), fn line, acc ->
        acc
        |> add_quantity("required_quantity", line.required)
        |> add_quantity("on_hand_quantity", line.on_hand)
        |> add_quantity("shortfall_quantity", line.to_order)
        |> add_quantity("ordered_quantity", line.to_order)
        |> LineExplanation.merge_into(%{"explanation" => line.explanation})
      end)
    end)
  end

  @doc """
  The supplier order line of a plan line, the shape generation has always
  written: `ordered_quantity = shortfall_quantity = to_order`.
  """
  @spec order_line(map()) :: map()
  def order_line(line) do
    %{
      "item_uuid" => line.item_uuid,
      "name" => line.name,
      "sku" => line.sku,
      "unit" => line.unit,
      "catalogue_uuid" => line.catalogue_uuid,
      "required_quantity" => line.required,
      "on_hand_quantity" => line.on_hand,
      "shortfall_quantity" => line.to_order,
      "ordered_quantity" => line.to_order,
      "base_price" => line.base_price
    }
    |> LineExplanation.put(line.explanation)
  end

  defp add_quantity(line, key, qty),
    do: Map.put(line, key, Decimal.add(StockLedger.to_decimal(line[key]), qty))

  @doc """
  The lines of a draft after `new_lines` (lines of `assemble/2`) are
  appended to it. An item the draft does not have goes to the end. An item it
  has grows in its first line (the one posting keeps):
  `ordered_quantity` adds the new quantity, `shortfall_quantity` becomes the
  new `ordered_quantity` (so "Add 10% reserve" keeps what was appended and
  does not inflate a line the keeper reduced), `on_hand_quantity` is the
  plan's, the explanations are merged; every other key of the draft's line
  stays as it is.

  `required_quantity` follows `opts[:required]`:
    * `:replace` (the default, a draft of this internal order alone) - the
      plan's requirement;
    * `{:add_except, items}` (a combined draft) - the line's requirement is
      the sum over its internal orders, so this order's is added, unless the
      item is in `items` (this order's ref already counts it);
    * `:keep` - left as it is.
  """
  @spec merge_into([map()], [map()], keyword()) :: [map()]
  def merge_into(draft_lines, new_lines, opts \\ []) do
    rule = Keyword.get(opts, :required, :replace)

    Enum.reduce(new_lines, draft_lines, fn new_line, lines ->
      item_uuid = new_line["item_uuid"]

      case Enum.find_index(lines, &(&1["item_uuid"] == item_uuid)) do
        nil -> lines ++ [new_line]
        index -> List.update_at(lines, index, &grow_line(&1, new_line, rule))
      end
    end)
  end

  @doc """
  The lines an order of `assemble/2` leaves in its draft: its own lines for a
  new draft, else the target's lines with them merged in (`merge_into/3`;
  the requirement of a combined target is added to, see there). What
  `SupplierOrders.apply_plan/5` writes.
  """
  @spec target_lines(map(), Ecto.UUID.t()) :: [map()]
  def target_lines(%{target: :new, lines: lines}, _io_uuid), do: lines

  def target_lines(%{target: target, lines: lines}, io_uuid) do
    merge_into(target.lines, lines,
      required: required_rule(target.single_source?, target.source_refs, io_uuid)
    )
  end

  defp required_rule(true, _refs, _io_uuid), do: :replace

  defp required_rule(false, refs, io_uuid) do
    case io_ref(refs, io_uuid) do
      %{"lines" => lines} when is_map(lines) -> {:add_except, MapSet.new(Map.keys(lines))}
      _whole_document_or_none -> :keep
    end
  end

  defp grow_line(line, new_line, rule) do
    ordered =
      Decimal.add(
        StockLedger.to_decimal(line["ordered_quantity"]),
        StockLedger.to_decimal(new_line["ordered_quantity"])
      )

    line
    |> Map.merge(%{
      "ordered_quantity" => ordered,
      "shortfall_quantity" => ordered,
      "required_quantity" => required(line, new_line, rule),
      "on_hand_quantity" => new_line["on_hand_quantity"]
    })
    |> LineExplanation.merge_into(new_line)
  end

  defp required(_line, new_line, :replace), do: new_line["required_quantity"]
  defp required(line, _new_line, :keep), do: line["required_quantity"]

  defp required(line, new_line, {:add_except, counted}) do
    if MapSet.member?(counted, line["item_uuid"]) do
      line["required_quantity"]
    else
      Decimal.add(
        StockLedger.to_decimal(line["required_quantity"]),
        StockLedger.to_decimal(new_line["required_quantity"])
      )
    end
  end
end
