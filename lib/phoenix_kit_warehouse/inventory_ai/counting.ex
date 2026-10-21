defmodule PhoenixKitWarehouse.InventoryAI.Counting do
  @moduledoc """
  Turns what the model saw - packages, their fill, loose units, a measured
  quantity - into the quantity of the item's own unit (spec §9). All
  arithmetic is `Decimal`.

  | Unit of the item                          | Known                              | Result |
  |-------------------------------------------|------------------------------------|--------|
  | piece, pair, set, sheet, pack             | only loose units                   | the loose units |
  | piece, pair, set, sheet, pack             | packages and units per package `n` | `closed × n + floor(open × n × fill) + loose` |
  | piece, pair, set, sheet                   | packages, `n` unknown              | `{:needs, :package_size}` - `n` or the quantity typed by a person |
  | pack                                      | packages, `n` unknown              | `closed + open × fill`, down to 0.1, `+ loose` |
  | m2, running_meter, kg, litre, m3          | the model's quantity               | `{:measured, quantity}` - never checked by default |
  | m2, running_meter, kg, litre, m3          | no quantity                        | `{:needs, :quantity}` |

  `floor` is only for the share of the open packages of a piece unit, never
  for the whole. The model's `quantity` of a piece unit is not used. A unit
  the table does not name (`roll`, a service unit) and an object with
  nothing counted need the quantity typed. `n` from the label wins over
  the one a person typed for the row.
  """

  alias PhoenixKitWarehouse.StockLedger

  @piece_units ~w(piece pair set sheet pack)
  @measured_units ~w(m2 running_meter kg litre m3)

  @zero Decimal.new(0)

  @type outcome ::
          {:counted, Decimal.t(), String.t()}
          | {:measured, Decimal.t(), String.t()}
          | {:needs, :package_size | :quantity}

  @doc """
  The quantity of one checked object (see `PhoenixKitWarehouse.InventoryAI.Response`)
  in `unit`; `package_size` is the units per package a person typed for the
  row, used where the label gave none.
  """
  @spec count(map(), String.t() | nil, Decimal.t() | nil) :: outcome()
  def count(object, unit, package_size \\ nil)

  def count(object, unit, package_size) when unit in @piece_units do
    closed = number(object["closed_packages"]) || @zero
    open = number(object["open_packages"]) || @zero
    fill = number(object["open_fill"]) || @zero
    loose = number(object["loose_units"])
    per_package = number(object["units_per_package"]) || positive(package_size)

    cond do
      Decimal.eq?(Decimal.add(closed, open), 0) ->
        if loose, do: {:counted, loose, format(loose)}, else: {:needs, :quantity}

      per_package ->
        by_package(closed, open, fill, per_package, loose)

      unit == "pack" ->
        packs(closed, open, fill, loose)

      true ->
        {:needs, :package_size}
    end
  end

  def count(object, unit, _package_size) when unit in @measured_units do
    case number(object["quantity"]) do
      nil -> {:needs, :quantity}
      quantity -> {:measured, quantity, format(quantity)}
    end
  end

  def count(_object, _unit, _package_size), do: {:needs, :quantity}

  @doc """
  The quantity of a row of the proposal - every object the model saw of one
  item. The objects add up; one that needs the quantity typed makes the row
  need it, else one that needs the units per package makes the row need
  those. The third element is the formula of each object, in order.
  """
  @spec count_all([map()], String.t() | nil, Decimal.t() | nil) ::
          {:counted | :measured, Decimal.t(), [String.t()]} | {:needs, :package_size | :quantity}
  def count_all(objects, unit, package_size \\ nil) do
    outcomes = Enum.map(objects, &count(&1, unit, package_size))

    cond do
      {:needs, :quantity} in outcomes ->
        {:needs, :quantity}

      {:needs, :package_size} in outcomes ->
        {:needs, :package_size}

      outcomes == [] ->
        {:needs, :quantity}

      true ->
        [{kind, _, _} | _] = outcomes
        total = Enum.reduce(outcomes, @zero, fn {_kind, qty, _}, acc -> Decimal.add(acc, qty) end)
        {kind, total, Enum.map(outcomes, &elem(&1, 2))}
    end
  end

  # closed × n + floor(open × n × fill) + loose
  defp by_package(closed, open, fill, per_package, loose) do
    share = open |> Decimal.mult(per_package) |> Decimal.mult(fill) |> Decimal.round(0, :floor)
    full = Decimal.mult(closed, per_package)
    total = full |> Decimal.add(share) |> Decimal.add(loose || @zero)

    formula =
      terms([
        nonzero(closed) && "#{format(closed)}×#{format(per_package)}",
        nonzero(open) && "⌊#{format(open)}×#{format(per_package)}×#{format(fill)}⌋",
        nonzero(loose) && format(loose)
      ]) <> " = #{format(total)}"

    {:counted, total, formula}
  end

  # closed + open × fill, down to 0.1 (+ loose)
  defp packs(closed, open, fill, loose) do
    packages = closed |> Decimal.add(Decimal.mult(open, fill)) |> Decimal.round(1, :floor)
    total = Decimal.add(packages, loose || @zero)

    formula =
      terms([
        nonzero(closed) && format(closed),
        nonzero(open) && "#{format(open)}×#{format(fill)}",
        nonzero(loose) && format(loose)
      ]) <> " = #{format(total)}"

    {:counted, total, formula}
  end

  # The terms of a formula without the zero ones (no open packages, say).
  # The callers come here only with closed or open packages, so one term is
  # always there; "0" only guards the join.
  defp terms(parts) do
    case Enum.filter(parts, & &1) do
      [] -> "0"
      shown -> Enum.join(shown, " + ")
    end
  end

  defp nonzero(%Decimal{} = value), do: not Decimal.eq?(value, 0)
  defp nonzero(_value), do: false

  defp positive(%Decimal{} = value), do: if(Decimal.gt?(value, 0), do: value, else: nil)
  defp positive(_value), do: nil

  # A checked object holds Decimals; one read back from jsonb holds their text.
  defp number(%Decimal{} = value), do: value
  defp number(value) when is_binary(value), do: StockLedger.to_decimal_or_nil(value)
  defp number(value) when is_integer(value), do: Decimal.new(value)
  defp number(_value), do: nil

  defp format(value), do: StockLedger.format_quantity(value)
end
