defmodule PhoenixKitWarehouse.InventoryAI.Lines do
  @moduledoc """
  The line of an inventory document and what a photo run does to it (spec
  §10.4, §11.2, §11.3) - pure functions over the line maps.

  Keys a line may carry beside the document's own:

    * `"counted_by"` - who gave the number: `"stock"` (seeded by
      `PhoenixKitWarehouse.Inventories.seed_lines/2`, with
      `"seeded_quantity"`), `"manual"` (a person), `"ai"` (a run applied);
    * `"base_qty"`, `"base_source"` (`"stock"` | `"manual"`) - the part of
      the number that is not the AI's;
    * `"ai_parts"` - the contribution of each run:
      `[%{"run_uuid", "place", "qty", "basis"}]`; `"ai_basis"` - their
      bases joined with `"; "`;
    * `"ai_parts_history"` - the parts a later hand edit took over, kept for
      reference and never summed.

  **Invariant**: a line with `ai_parts` has
  `counted_quantity = base_qty + Σ qty` (`base_qty` 0 when absent). A line
  whose parts no longer add up was changed some other way, and is a manual
  one.

  The actions (`choices/3` gives the default and the switch):

  | Line                                | Default         | Switch |
  |-------------------------------------|-----------------|--------|
  | none                                | `"new"`         | - |
  | seeded                              | `"replace"`     | `"add"` (the seeded number is the base) |
  | the AI's, a part of the same place  | `"replace_part"`| `"add_part"`, `"replace_all"` |
  | the AI's, no part of this place     | `"add_part"`    | `"replace_all"` |
  | manual                              | `"add"`         | `"replace_all"` |

  "The same place": both labels non-empty and equal after trimming and
  case; an empty label is never the same place.
  """

  alias PhoenixKitWarehouse.StockLedger

  @zero Decimal.new(0)

  @type kind :: :none | :seeded | :ai | :manual
  @type part :: %{required(String.t()) => term()}

  @doc "A quantity of a line as a Decimal (the socket holds Decimals, jsonb their text); `nil` when it is not one."
  @spec decimal(term()) :: Decimal.t() | nil
  def decimal(value), do: StockLedger.to_decimal_or_nil(value)

  @doc "Whether two place labels name the same place."
  @spec same_place?(String.t() | nil, String.t() | nil) :: boolean()
  def same_place?(a, b) do
    case {normalize_place(a), normalize_place(b)} do
      {"", _} -> false
      {_, ""} -> false
      {same, same} -> true
      _ -> false
    end
  end

  defp normalize_place(label) when is_binary(label),
    do: label |> String.trim() |> String.downcase()

  defp normalize_place(_label), do: ""

  @doc """
  The kind of `line` given the stock of its item on the document's
  warehouse (`nil` when there is no stock row). A line without a label
  (made before `counted_by` existed) is seeded when its number equals the
  stock (`Decimal.eq?`), otherwise manual.
  """
  @spec kind(map() | nil, Decimal.t() | nil) :: kind()
  def kind(nil, _stock), do: :none

  def kind(line, stock) do
    cond do
      ai_parts(line) != [] and invariant?(line) -> :ai
      line["counted_by"] == "stock" -> :seeded
      line["counted_by"] in ["manual", "ai"] -> :manual
      unlabelled_seeded?(line, stock) -> :seeded
      true -> :manual
    end
  end

  defp unlabelled_seeded?(line, %Decimal{} = stock) do
    is_nil(line["counted_by"]) and ai_parts(line) == [] and
      match?(%Decimal{}, decimal(line["counted_quantity"])) and
      Decimal.eq?(decimal(line["counted_quantity"]), stock)
  end

  defp unlabelled_seeded?(_line, _stock), do: false

  @doc """
  The default action for a run of `place` on `line`, and the actions the
  switch offers (spec §11.2).
  """
  @spec choices(map() | nil, Decimal.t() | nil, String.t() | nil) ::
          %{kind: kind(), default: String.t(), actions: [String.t()]}
  def choices(line, stock, place) do
    case kind(line, stock) do
      :none ->
        %{kind: :none, default: "new", actions: ["new"]}

      :seeded ->
        %{kind: :seeded, default: "replace", actions: ["replace", "add"]}

      :ai ->
        if Enum.any?(ai_parts(line), &same_place?(&1["place"], place)),
          do: %{
            kind: :ai,
            default: "replace_part",
            actions: ["replace_part", "add_part", "replace_all"]
          },
          else: %{kind: :ai, default: "add_part", actions: ["add_part", "replace_all"]}

      :manual ->
        %{kind: :manual, default: "add", actions: ["add", "replace_all"]}
    end
  end

  @doc """
  The line after `action` with the run's `part`
  (`%{"run_uuid", "place", "qty", "basis"}`); `new_line` is the line to
  start from when there is none. `stock` is what the kind of the line was
  read with. Raises `ArgumentError` for an action outside `choices/3`.
  After any action the line is `counted_by: "ai"` and keeps the invariant.
  """
  @spec apply(map() | nil, String.t(), part(), map(), Decimal.t() | nil) :: map()
  def apply(line, action, part, new_line, stock \\ nil) do
    %{kind: kind, actions: actions} = choices(line, stock, part["place"])

    unless action in actions do
      raise ArgumentError, "action #{inspect(action)} is not one of #{inspect(actions)}"
    end

    part = Map.update!(part, "qty", &decimal/1)

    case {kind, action} do
      {:none, "new"} ->
        new_line |> with_parts(@zero, nil, [part])

      {_kind, "replace"} ->
        with_parts(line, @zero, nil, [part])

      {_kind, "replace_all"} ->
        line |> retire_stale_parts(kind) |> with_parts(@zero, nil, [part])

      {:seeded, "add"} ->
        with_parts(line, counted!(line), "stock", [part])

      {:manual, "add"} ->
        line |> retire_stale_parts(kind) |> with_parts(counted!(line), "manual", [part])

      {:ai, "add_part"} ->
        with_parts(line, base(line), line["base_source"], ai_parts(line) ++ [part])

      {:ai, "replace_part"} ->
        with_parts(line, base(line), line["base_source"], replace_part(line, part))
    end
  end

  # The parts of the same place give way to the new one, which takes the
  # place of the first of them.
  defp replace_part(line, part) do
    {before, rest} =
      Enum.split_while(ai_parts(line), &(not same_place?(&1["place"], part["place"])))

    before ++ [part | Enum.reject(rest, &same_place?(&1["place"], part["place"]))]
  end

  # A manual line may still carry parts that no longer add up: they go to the
  # history, never into the new sum.
  defp retire_stale_parts(line, :manual) do
    case ai_parts(line) do
      [] ->
        line

      parts ->
        line |> Map.delete("ai_parts") |> Map.update("ai_parts_history", parts, &(&1 ++ parts))
    end
  end

  defp retire_stale_parts(line, _kind), do: line

  defp with_parts(line, base_qty, base_source, parts) do
    total = Enum.reduce(parts, base_qty, &Decimal.add(decimal(&1["qty"]), &2))

    line
    |> Map.delete("_sum")
    |> put_or_delete("base_source", base_source)
    |> Map.merge(%{
      "counted_quantity" => total,
      "counted_by" => "ai",
      "base_qty" => base_qty,
      "ai_parts" => parts,
      "ai_basis" =>
        parts |> Enum.map(&(&1["basis"] || "")) |> Enum.reject(&(&1 == "")) |> Enum.join("; ")
    })
  end

  defp put_or_delete(map, key, nil), do: Map.delete(map, key)
  defp put_or_delete(map, key, value), do: Map.put(map, key, value)

  defp counted!(line) do
    case decimal(line["counted_quantity"]) do
      %Decimal{} = qty -> qty
      nil -> raise ArgumentError, "the line's counted_quantity is not a number"
    end
  end

  defp base(line), do: decimal(line["base_qty"]) || @zero

  defp ai_parts(%{"ai_parts" => parts}) when is_list(parts), do: parts
  defp ai_parts(_line), do: []

  @doc "Whether a line with `ai_parts` holds `counted_quantity = base_qty + Σ qty` (a line without them always does)."
  @spec invariant?(map()) :: boolean()
  def invariant?(line) do
    case ai_parts(line) do
      [] ->
        true

      parts ->
        quantities = Enum.map(parts, &decimal(&1["qty"]))
        counted = decimal(line["counted_quantity"])
        base = if Map.has_key?(line, "base_qty"), do: decimal(line["base_qty"]), else: @zero

        Enum.all?([counted, base | quantities], &match?(%Decimal{}, &1)) and
          Decimal.eq?(counted, Enum.reduce(quantities, base, &Decimal.add/2))
    end
  end

  @doc """
  A person typed `qty` into the line (spec §10.4): it is their count now -
  `counted_by: "manual"`, the base, and the runs' parts move to
  `ai_parts_history`. Typing the seeded number is a count too.
  """
  @spec manual_edit(map(), Decimal.t()) :: map()
  def manual_edit(line, %Decimal{} = qty) do
    line
    |> retire_parts()
    |> Map.delete("ai_basis")
    |> Map.merge(%{
      "counted_quantity" => qty,
      "counted_by" => "manual",
      "base_qty" => qty,
      "base_source" => "manual"
    })
  end

  defp retire_parts(line) do
    case ai_parts(line) do
      [] ->
        Map.delete(line, "ai_parts")

      parts ->
        line |> Map.delete("ai_parts") |> Map.update("ai_parts_history", parts, &(&1 ++ parts))
    end
  end

  @doc "Below the stock: the total under the stock of the item (spec §11.3)."
  @spec below_stock?(Decimal.t(), Decimal.t() | nil) :: boolean()
  def below_stock?(%Decimal{} = total, %Decimal{} = stock), do: Decimal.lt?(total, stock)
  def below_stock?(_total, _stock), do: false

  @doc "Sharply below: 0 against a stock above 0, or under half the stock."
  @spec sharply_below_stock?(Decimal.t(), Decimal.t() | nil) :: boolean()
  def sharply_below_stock?(%Decimal{} = total, %Decimal{} = stock) do
    (Decimal.eq?(total, 0) and Decimal.gt?(stock, 0)) or
      Decimal.lt?(Decimal.mult(total, 2), stock)
  end

  def sharply_below_stock?(_total, _stock), do: false

  @doc """
  Whether a row of the proposal is ticked by default (spec §11.3), and the
  reasons when it is not. Ticked only when: an item is chosen; both
  confidences are high or medium; the code counted the quantity (not typed,
  not measured); the total is not sharply below the stock; the item has a
  star or a line already; the line is not a manual one.

  `row`: `item?`, `match_confidence`, `count_confidence`, `count_kind`
  (`:counted`, `:measured`, `:package_size`, `:quantity`), `total` (the
  line's total after the action, `nil` while unknown), `stock`, `starred?`,
  `line_kind` (`kind/2`).
  """
  @spec default_check(map()) :: {boolean(), [atom()]}
  def default_check(row) do
    reasons =
      [
        {not row.item?, :no_item},
        {row.match_confidence not in ["high", "medium"], :low_match},
        {row.count_confidence not in ["high", "medium"], :low_count},
        {row.count_kind == :measured, :measured},
        {row.count_kind in [:package_size, :quantity], :needs_input},
        {sharply_below_stock?(row.total, row.stock), :sharply_below_stock},
        {row.line_kind == :none and not row.starred?, :new_without_star},
        {row.line_kind == :manual, :manual_line}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    {reasons == [], reasons}
  end
end
