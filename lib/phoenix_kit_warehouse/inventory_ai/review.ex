defmodule PhoenixKitWarehouse.InventoryAI.Review do
  @moduledoc """
  The proposal of a run as a person reviews it before Apply (spec §5.4,
  §11.2, §11.3) - pure functions over the run's rows; the page keeps the
  review in its socket, so a reload shows the run's proposal again, without
  the edits.

  A row of the review stands for one or more rows of the proposal
  (`"row"` numbers of the run's `result`): choosing for a row an item another
  row already holds merges the two at once - one row, their counts summed,
  one switch - so that the lines never get two lines of one item;
  `unmerge/2` puts the rows of the run back. A row keeps what the person
  changed: the item, the quantity typed (`nil` while the count stands), the
  units per package typed, the rule chosen in the switch (`nil` for the
  line's default) and the tick (`nil` for the default).

  `view/3` computes, against the tab's lines and the stock of the
  document's warehouse, what the table shows: the count, the line the row
  meets and what it becomes, the default tick and the reasons it is not
  ticked. `apply_rows/3` gives the ticked rows in the shape
  `PhoenixKitWarehouse.InventoryAI.apply_run/6` takes.
  """

  alias PhoenixKit.Utils.Number
  alias PhoenixKitWarehouse.InventoryAI.Lines
  alias PhoenixKitWarehouse.InventoryAI.Proposal
  alias PhoenixKitWarehouse.StockLedger

  @confidence_rank %{"high" => 2, "medium" => 1, "low" => 0}
  @kinds %{
    "counted" => :counted,
    "measured" => :measured,
    "package_size" => :package_size,
    "quantity" => :quantity,
    "item" => :item
  }

  @type entry :: %{
          key: pos_integer(),
          rows: [pos_integer()],
          item: map() | nil,
          quantity: String.t() | nil,
          package_size: String.t(),
          action: String.t() | nil,
          checked: boolean() | nil,
          accepted: boolean() | nil
        }

  @type t :: %{
          run_uuid: String.t(),
          place: String.t() | nil,
          proposal: %{pos_integer() => map()},
          rows: [entry()],
          errors: %{pos_integer() => %{String.t() => atom()}}
        }

  @doc "The review of a run's proposal, as the run proposed it."
  @spec new(PhoenixKitWarehouse.InventoryAIRun.t()) :: t()
  def new(run) do
    rows = (run.result || %{})["rows"] || []

    %{
      run_uuid: run.uuid,
      place: run.place_label,
      proposal: Map.new(rows, &{&1["row"], &1}),
      rows: Enum.map(rows, &initial(&1["row"], &1)),
      errors: %{}
    }
  end

  defp initial(number, proposed) do
    %{
      key: number,
      rows: [number],
      item: proposed["item"],
      quantity: nil,
      package_size: "",
      action: nil,
      checked: nil,
      accepted: nil
    }
  end

  # --- changes ------------------------------------------------------------------------

  @doc """
  The item of row `key` is `item` (catalogue facts: `"item_uuid"`, `"name"`,
  `"sku"`, `"unit"`, ...). The typed values, the switch and the tick start
  over. When another row holds the item, the two merge into the first of
  them.
  """
  @spec choose(t(), pos_integer(), map()) :: {:ok, t()} | {:error, :unknown_row}
  def choose(review, key, %{"item_uuid" => item_uuid} = item) do
    with {:ok, entry} <- fetch(review, key) do
      chosen = %{
        entry
        | item: item,
          quantity: nil,
          package_size: "",
          action: nil,
          checked: nil,
          accepted: nil
      }

      case Enum.find(review.rows, &(&1.key != key and item_uuid?(&1, item_uuid))) do
        nil -> {:ok, replace(review, key, chosen)}
        other -> {:ok, merge(review, chosen, other)}
      end
    end
  end

  defp item_uuid?(%{item: %{"item_uuid" => uuid}}, uuid), do: true
  defp item_uuid?(_entry, _uuid), do: false

  defp merge(review, chosen, other) do
    {first, second} =
      if position(review, chosen.key) < position(review, other.key),
        do: {chosen, other},
        else: {other, chosen}

    merged = %{
      key: first.key,
      rows: first.rows ++ second.rows,
      item: chosen.item,
      quantity: merged_quantity(review, chosen, other),
      package_size: other.package_size,
      action: nil,
      checked: nil,
      accepted: nil
    }

    review
    |> Map.update!(:rows, fn rows -> Enum.reject(rows, &(&1.key == second.key)) end)
    |> replace(first.key, merged)
  end

  # The counts of both rows when neither was typed (counted again together);
  # a typed one is summed with the other's quantity, or left to be typed when
  # the other has none.
  defp merged_quantity(_review, _chosen, %{quantity: nil}), do: nil

  defp merged_quantity(review, chosen, other) do
    with {:ok, a} <- parse(other.quantity),
         {:ok, b} <- parse(display_quantity(review, chosen)) do
      format(Decimal.add(a, b))
    else
      _ -> ""
    end
  end

  defp position(review, key), do: Enum.find_index(review.rows, &(&1.key == key))

  @doc """
  Splits a merged row back into the rows of the run, each as the run
  proposed it. A row whose proposed item another row holds meanwhile comes
  back without an item, so that two rows never hold one item.
  """
  @spec unmerge(t(), pos_integer()) :: {:ok, t()} | {:error, :unknown_row}
  def unmerge(review, key) do
    with {:ok, entry} <- fetch(review, key) do
      used =
        for other <- review.rows,
            other.key != key,
            other.item,
            into: MapSet.new(),
            do: other.item["item_uuid"]

      restored =
        Enum.map(entry.rows, fn number ->
          row = initial(number, review.proposal[number])

          if row.item && MapSet.member?(used, row.item["item_uuid"]),
            do: %{row | item: nil},
            else: row
        end)

      rows = Enum.flat_map(review.rows, &if(&1.key == key, do: restored, else: [&1]))
      {:ok, %{review | rows: rows}}
    end
  end

  @doc """
  The inputs of a row as its form sends them: `"quantity"` (typed only when
  it differs from what the row shows), `"package_size"`, `"action"`.

  A quantity typed is a person's correction, and so their consent: a row
  still on its default tick keeps the tick it showed before the edit (in
  the view against `lines` and `stock_map`), rather than the default of a
  typed row, which is never ticked.
  """
  @spec set_inputs(t(), pos_integer(), map(), [map()], map()) ::
          {:ok, t()} | {:error, :unknown_row}
  def set_inputs(review, key, params, lines, stock_map) do
    with {:ok, entry} <- fetch(review, key) do
      shown = display_quantity(review, entry)

      entry =
        entry
        |> then(fn entry ->
          case params do
            %{"quantity" => value} when is_binary(value) and value != shown ->
              accept_edit(review, entry, String.trim(value), lines, stock_map)

            _ ->
              entry
          end
        end)
        |> then(fn entry ->
          case params do
            %{"package_size" => value} when is_binary(value) ->
              changed(entry, :package_size, String.trim(value))

            _ ->
              entry
          end
        end)
        |> then(fn entry ->
          case params do
            %{"action" => value} when is_binary(value) and value != "" ->
              changed(entry, :action, value)

            _ ->
              entry
          end
        end)

      {:ok, replace(review, key, entry)}
    end
  end

  # A change of the pack size or of the rule moves the total like a typed
  # quantity: a tick the person set before it becomes a consent the view
  # takes back while the row is far below the stock.
  defp changed(entry, field, value) do
    if Map.fetch!(entry, field) == value do
      entry
    else
      entry
      |> Map.put(field, value)
      |> then(&if(&1.checked == true, do: %{&1 | checked: nil, accepted: true}, else: &1))
    end
  end

  # A typed quantity is a person's correction, and so their consent: the row
  # keeps the tick it showed (`accepted`), a tick the person set included,
  # and `view/3` takes it back while the row is far below the stock (a
  # dropped digit, a 0), whatever later changes the total. A row the person
  # unticked stays unticked; a tick set after the edit stands as it is.
  defp accept_edit(review, entry, quantity, lines, stock_map) do
    accepted =
      cond do
        is_boolean(entry.checked) -> entry.checked
        is_boolean(entry.accepted) -> entry.accepted
        true -> view_row(review, entry, lines, stock_map).checked
      end

    %{
      entry
      | quantity: quantity,
        checked: if(entry.checked == false, do: false, else: nil),
        accepted: accepted
    }
  end

  @doc "Ticks or unticks a row (a row without an item stays unticked)."
  @spec set_checked(t(), pos_integer(), boolean()) :: {:ok, t()} | {:error, :unknown_row}
  def set_checked(review, key, checked?) when is_boolean(checked?) do
    with {:ok, entry} <- fetch(review, key) do
      {:ok, replace(review, key, %{entry | checked: checked?})}
    end
  end

  @doc """
  The item a row may be switched to by its number in the run's catalogue:
  one of the row's alternatives or the item the run proposed for one of its
  rows, else `nil`.
  """
  @spec offered_item(t(), pos_integer(), integer()) :: map() | nil
  def offered_item(review, key, number) do
    case fetch(review, key) do
      {:ok, entry} -> Enum.find(offered(review, entry), &(&1["no"] == number))
      _ -> nil
    end
  end

  defp offered(review, entry) do
    proposed = Enum.map(entry.rows, &review.proposal[&1])

    (Enum.flat_map(proposed, &(&1["alternatives"] || [])) ++
       Enum.flat_map(proposed, &List.wrap(&1["item"])))
    |> Enum.uniq_by(& &1["item_uuid"])
  end

  @doc """
  The field errors of a refused Apply (`%{row: number, field, error}`), on
  the rows that hold those numbers; `[]` clears them.
  """
  @spec put_errors(t(), [map()]) :: t()
  def put_errors(review, errors) do
    by_key =
      Enum.reduce(errors, %{}, fn error, acc ->
        case Enum.find(review.rows, &(error[:row] in &1.rows)) do
          nil ->
            acc

          entry ->
            Map.update(
              acc,
              entry.key,
              %{error.field => error.error},
              &Map.put(&1, error.field, error.error)
            )
        end
      end)

    %{review | errors: by_key}
  end

  defp fetch(review, key) do
    case Enum.find(review.rows, &(&1.key == key)) do
      nil -> {:error, :unknown_row}
      entry -> {:ok, entry}
    end
  end

  defp replace(review, key, entry) do
    %{review | rows: Enum.map(review.rows, &if(&1.key == key, do: entry, else: &1))}
  end

  # --- what the table shows -----------------------------------------------------------

  @doc """
  The rows as the table shows them, against the tab's `lines` and the
  `stock_map` of the document's warehouse (`item_uuid => %{quantity: qty}`).
  """
  @spec view(t(), [map()], map()) :: [map()]
  def view(review, lines, stock_map) do
    Enum.map(review.rows, &view_row(review, &1, lines, stock_map))
  end

  defp view_row(review, entry, lines, stock_map) do
    proposed = Enum.map(entry.rows, &review.proposal[&1])
    count = count(entry, proposed)
    kind = kind(entry, count)
    quantity = entry.quantity || count_text(count)
    item_uuid = entry.item && entry.item["item_uuid"]
    stock = item_uuid && stock_qty(stock_map, item_uuid)
    {line_kind, line} = line(lines, item_uuid, stock)

    %{actions: actions, default: default} =
      case line_kind do
        :repeated -> %{actions: [], default: nil}
        _ -> Lines.choices(line, stock, review.place)
      end

    action = if entry.action in actions, do: entry.action, else: default
    total = total(review, line, line_kind, action, quantity, item_uuid, stock)
    match = weakest(proposed, "match_confidence")
    count_confidence = weakest(proposed, "count_confidence")
    starred? = is_binary(item_uuid) and Map.has_key?(stock_map, item_uuid)

    {default_checked, reasons} =
      default_check(%{
        item?: not is_nil(entry.item),
        match_confidence: match,
        count_confidence: count_confidence,
        kind: kind,
        total: total,
        stock: stock,
        starred?: starred?,
        line_kind: line_kind
      })

    %{
      key: entry.key,
      rows: entry.rows,
      merged?: length(entry.rows) > 1,
      item: entry.item,
      alternatives: Enum.reject(offered(review, entry), &(&1["item_uuid"] == item_uuid)),
      photos: proposed |> Enum.flat_map(&(&1["photos"] || [])) |> Enum.uniq() |> Enum.sort(),
      description: join(proposed, "description"),
      ai_basis: join(proposed, "ai_basis"),
      formulas: count["formulas"] || [],
      match_confidence: match,
      count_confidence: count_confidence,
      kind: kind,
      quantity: quantity,
      package_size: entry.package_size,
      action: action,
      actions: actions,
      line: line_info(line_kind, line, stock),
      stock: stock,
      starred?: starred?,
      total: total,
      checked: not is_nil(entry.item) and tick(entry, default_checked, reasons),
      default_checked: default_checked,
      reasons: reasons,
      errors: Map.get(review.errors, entry.key, %{})
    }
  end

  # The person's own tick wins; a typed correction keeps the tick it was
  # made on unless the row is far below the stock; else the default.
  defp tick(%{checked: checked}, _default, _reasons) when is_boolean(checked), do: checked

  defp tick(%{accepted: accepted}, _default, reasons) when is_boolean(accepted),
    do: accepted and :sharply_below_stock not in reasons

  defp tick(_entry, default, _reasons), do: default

  defp count(%{item: nil}, proposed),
    do: proposed |> Enum.flat_map(&(&1["objects"] || [])) |> Proposal.waiting_for_item()

  defp count(entry, proposed) do
    objects = Enum.flat_map(proposed, &(&1["objects"] || []))

    package_size =
      case Number.parse_decimal(entry.package_size, min: 0) do
        {:ok, size} -> if Decimal.gt?(size, 0), do: size, else: nil
        _ -> nil
      end

    Proposal.recount(%{"objects" => objects}, entry.item["unit"], package_size)
  end

  defp kind(%{item: nil}, _count), do: :item
  defp kind(%{quantity: typed}, _count) when is_binary(typed), do: :typed
  defp kind(_entry, %{"kind" => kind}), do: Map.fetch!(@kinds, kind)

  defp count_text(%{"quantity" => nil}), do: ""
  defp count_text(%{"quantity" => quantity}), do: format(StockLedger.to_decimal_or_nil(quantity))

  defp display_quantity(review, entry) do
    entry.quantity || count_text(count(entry, Enum.map(entry.rows, &review.proposal[&1])))
  end

  defp stock_qty(stock_map, item_uuid) do
    case Map.get(stock_map, item_uuid) do
      %{quantity: quantity} -> Lines.decimal(quantity)
      _ -> nil
    end
  end

  defp line(_lines, nil, _stock), do: {:none, nil}

  defp line(lines, item_uuid, stock) do
    case Enum.filter(lines, &(&1["item_uuid"] == item_uuid)) do
      [] -> {:none, nil}
      [line] -> {Lines.kind(line, stock), line}
      [line | _] -> {:repeated, line}
    end
  end

  # What the line becomes; `nil` while the quantity cannot be read.
  defp total(_review, _line, :repeated, _action, _quantity, _item_uuid, _stock), do: nil
  defp total(_review, _line, _kind, nil, _quantity, _item_uuid, _stock), do: nil

  defp total(review, line, _kind, action, quantity, item_uuid, stock) do
    case parse(quantity) do
      {:ok, qty} ->
        part = %{"run_uuid" => review.run_uuid, "place" => review.place, "qty" => qty}
        new_line = %{"item_uuid" => item_uuid, "counted_quantity" => Decimal.new(0)}
        Lines.apply(line, action, part, new_line, stock)["counted_quantity"]

      :error ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp default_check(row) do
    count_kind = if row.kind in [:typed, :item], do: :quantity, else: row.kind

    {_checked, reasons} =
      Lines.default_check(%{
        item?: row.item?,
        match_confidence: row.match_confidence,
        count_confidence: row.count_confidence,
        count_kind: count_kind,
        total: row.total,
        stock: row.stock,
        starred?: row.starred?,
        line_kind: if(row.line_kind == :repeated, do: :none, else: row.line_kind)
      })

    reasons =
      cond do
        not row.item? -> [:no_item]
        row.kind == :typed -> Enum.map(reasons, &if(&1 == :needs_input, do: :typed, else: &1))
        true -> reasons
      end

    reasons =
      if row.line_kind == :repeated, do: reasons ++ [:repeated_line], else: reasons

    {reasons == [], reasons}
  end

  defp line_info(:none, _line, _stock), do: nil

  defp line_info(kind, line, stock) do
    %{
      kind: kind,
      counted: Lines.decimal(line["counted_quantity"]),
      counted_by: line["counted_by"],
      base: Lines.decimal(line["base_qty"]),
      base_source: line["base_source"],
      parts: parts(line["ai_parts"]),
      history: parts(line["ai_parts_history"]),
      seeded: Lines.decimal(line["seeded_quantity"]),
      stock: stock
    }
  end

  defp parts(parts) when is_list(parts),
    do: Enum.map(parts, &{&1["place"], Lines.decimal(&1["qty"])})

  defp parts(_parts), do: []

  defp weakest(proposed, key) do
    proposed
    |> Enum.map(& &1[key])
    |> Enum.min_by(&Map.get(@confidence_rank, &1, 0), fn -> "low" end)
  end

  defp join(proposed, key) do
    proposed |> Enum.map(& &1[key]) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("; ")
  end

  # --- Apply --------------------------------------------------------------------------

  @doc """
  The ticked rows, as `PhoenixKitWarehouse.InventoryAI.apply_run/6` takes
  them: `"row"` (the first row of the run it stands for), `"merged_rows"`
  (the others), `"item_uuid"`, `"quantity"` (the text shown), `"action"`
  (the rule the table shows), `"package_size"`.
  """
  @spec apply_rows(t(), [map()], map()) :: [map()]
  def apply_rows(review, lines, stock_map) do
    for row <- view(review, lines, stock_map), row.checked do
      %{
        "row" => row.key,
        "merged_rows" => tl(row.rows),
        "item_uuid" => row.item["item_uuid"],
        "quantity" => row.quantity,
        "action" => row.action,
        "package_size" => row.package_size
      }
    end
  end

  defp parse(text) do
    case Number.parse_decimal(text, min: 0) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  defp format(nil), do: ""
  defp format(%Decimal{} = value), do: StockLedger.format_quantity(value)
end
