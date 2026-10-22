defmodule PhoenixKitWarehouse.Web.SupplierOrderPreview do
  @moduledoc false
  # The state of the "generate supplier orders" window of an internal order:
  # the plan, the person's choices (`%{key => supplier_uuid | "skip"}`), the
  # ticked lines of the "choose a supplier" block, and what the plan writes
  # with those choices (`SupplierOrders.assemble/2`). Pure: the LiveView reads
  # the plan, and the window is drawn from `assembled` only, so it shows what
  # `SupplierOrders.apply_plan/5` writes.

  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrderPlan
  alias PhoenixKitWarehouse.SupplierOrders

  @type t :: %{
          plan: map(),
          choices: %{String.t() => String.t()},
          checked: [String.t()],
          bulk_supplier: String.t() | nil,
          changed: [String.t()],
          stale?: boolean(),
          assembled: map()
        }

  @doc "A window on a fresh plan: no choices, nothing ticked."
  @spec new(map()) :: t()
  def new(plan) do
    reassemble(%{
      plan: plan,
      choices: %{},
      checked: [],
      bulk_supplier: nil,
      changed: [],
      stale?: false
    })
  end

  @doc """
  The window after its form changed: `"choice"` (a supplier per line key,
  `"skip"` for "do not order"), `"pick"` (ticked lines), `"pick_all"` (the
  tick of the whole block, when it is the `_target`) and `"bulk_supplier"`.
  A choice the line does not allow is ignored.
  """
  @spec change(t(), map()) :: t()
  def change(state, params) do
    lines = lines_by_key(state.plan)

    choices =
      params
      |> Map.get("choice", %{})
      |> Enum.reduce(state.choices, fn {key, value}, choices ->
        put_choice(choices, Map.get(lines, key), value)
      end)

    state
    |> Map.merge(%{choices: choices, bulk_supplier: bulk_supplier(state.plan, params)})
    |> Map.put(:checked, checked(params))
    |> reassemble()
    |> then(&maybe_pick_all(&1, params))
  end

  @doc "Gives the supplier of the bulk select to every ticked line."
  @spec assign_checked(t()) :: t()
  def assign_checked(%{bulk_supplier: nil} = state), do: state

  def assign_checked(state) do
    lines = lines_by_key(state.plan)

    choices =
      Enum.reduce(state.checked, state.choices, fn key, choices ->
        put_choice(choices, Map.get(lines, key), state.bulk_supplier)
      end)

    reassemble(%{state | choices: choices, checked: []})
  end

  @doc """
  The window on `new_plan` after the plan it showed went stale. A choice is
  kept when its line is still in the plan, can still be chosen and still
  allows that supplier; the rest are dropped. `changed` marks the lines whose
  choice was dropped, which are new, or whose quantities or supplier differ.
  """
  @spec restale(t(), map()) :: t()
  def restale(state, new_plan) do
    old_lines = lines_by_key(state.plan)
    new_lines = lines_by_key(new_plan)

    {choices, dropped} =
      Enum.reduce(state.choices, {%{}, []}, fn {key, choice}, {kept, dropped} ->
        if keeps?(Map.get(new_lines, key), choice),
          do: {Map.put(kept, key, choice), dropped},
          else: {kept, [key | dropped]}
      end)

    differ =
      for line <- new_plan.lines,
          signature(Map.get(old_lines, line.key)) != signature(line),
          do: line.key

    reassemble(%{
      state
      | plan: new_plan,
        choices: choices,
        changed: Enum.uniq(dropped ++ differ),
        stale?: true,
        bulk_supplier: bulk_supplier(new_plan, %{"bulk_supplier" => state.bulk_supplier})
    })
  end

  @doc "Drops one choice (a refused one) and assembles again."
  @spec drop_choice(t(), String.t()) :: t()
  def drop_choice(state, key), do: reassemble(%{state | choices: Map.delete(state.choices, key)})

  @doc """
  `%{created, appended, lines, not_ordered}` of the window: new drafts,
  drafts appended to, the supplier order lines written and the lines with
  something to order that are not ordered (`SupplierOrderPlan.unassigned/1`,
  what the flash after the write counts as well).
  """
  @spec summary(t()) :: map()
  def summary(%{assembled: assembled}) do
    {new, appended} = Enum.split_with(assembled.orders, &(&1.target == :new))

    %{
      created: length(new),
      appended: length(appended),
      lines: assembled.orders |> Enum.map(&length(&1.lines)) |> Enum.sum(),
      not_ordered: length(SupplierOrderPlan.unassigned(assembled))
    }
  end

  @doc "The plan line of `key`."
  @spec line(t(), String.t()) :: map() | nil
  def line(state, key), do: Enum.find(state.plan.lines, &(&1.key == key))

  # ---------------------------------------------------------------------------

  defp reassemble(state) do
    io_uuid = state.plan.internal_order.uuid
    assembled = SupplierOrders.assemble(state.plan, state.choices)

    orders =
      Enum.map(assembled.orders, fn order ->
        Map.put(order, :now_after, now_after(order, io_uuid))
      end)

    unplaced = Enum.map(assembled.unplaced, & &1.key)

    state
    |> Map.put(:assembled, %{assembled | orders: orders})
    |> Map.put(:checked, Enum.filter(state.checked, &(&1 in unplaced)))
  end

  # `%{item_uuid => {now, after}}`: the ordered quantity of each item of the
  # order in its target draft before and after the write (what posting keeps:
  # the first line of the item). Empty for a new draft.
  defp now_after(%{target: :new}, _io_uuid), do: %{}

  defp now_after(order, io_uuid) do
    after_lines = SupplierOrders.target_lines(order, io_uuid)

    Map.new(order.lines, fn %{"item_uuid" => item} ->
      {item, {ordered(order.target.lines, item), ordered(after_lines, item)}}
    end)
  end

  defp ordered(lines, item) do
    case Enum.find(lines, &(&1["item_uuid"] == item)) do
      nil -> Decimal.new("0")
      line -> StockLedger.to_decimal(line["ordered_quantity"])
    end
  end

  # A choice equal to what the line would get anyway is no choice: the line
  # keeps its automatic reason.
  defp put_choice(choices, %{choosable?: true} = line, value) do
    case normalize(value, line) do
      :none -> Map.delete(choices, line.key)
      :invalid -> choices
      choice -> Map.put(choices, line.key, choice)
    end
  end

  defp put_choice(choices, _line, _value), do: choices

  defp normalize("skip", %{auto_supplier_uuid: nil}), do: :none
  defp normalize("skip", _line), do: "skip"

  defp normalize(value, line) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} when uuid == line.auto_supplier_uuid -> :none
      {:ok, uuid} -> if uuid in line.choices, do: uuid, else: :invalid
      :error -> :invalid
    end
  end

  defp normalize(_value, _line), do: :invalid

  defp keeps?(%{choosable?: true}, "skip"), do: true
  defp keeps?(%{choosable?: true, choices: allowed}, uuid), do: uuid in allowed
  defp keeps?(_line, _choice), do: false

  defp signature(nil), do: nil

  defp signature(line) do
    {line.item_uuid, Enum.map([line.need, line.on_hand, line.in_transit, line.to_order], &qty/1),
     line.auto_supplier_uuid, line.reason}
  end

  defp qty(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string()

  defp checked(params) do
    for {key, "true"} <- Map.get(params, "pick", %{}), do: key
  end

  defp maybe_pick_all(state, %{"_target" => ["pick_all"]} = params) do
    checked =
      if params["pick_all"] == "true",
        do: Enum.map(state.assembled.unplaced, & &1.key),
        else: []

    %{state | checked: checked}
  end

  defp maybe_pick_all(state, _params), do: state

  defp bulk_supplier(plan, params) do
    with value when is_binary(value) <- Map.get(params, "bulk_supplier"),
         {:ok, uuid} <- Ecto.UUID.cast(value),
         true <- Enum.any?(plan.suppliers, &(&1.uuid == uuid)) do
      uuid
    else
      _ -> nil
    end
  end

  defp lines_by_key(plan), do: Map.new(plan.lines, &{&1.key, &1})
end
