defmodule PhoenixKitWarehouse.API.Quantity do
  @moduledoc """
  Reads and renders the quantities and unit values of the warehouse API tools.

  A quantity arrives as a decimal **string** (`"12"`, `"0.5"`) or as a JSON
  number. It is accepted when it is between 0 and 1 000 000 000 and has at
  most 6 decimal places, with no sign, no thousands separator and no exponent
  (`"1e999999"` is refused before any arithmetic happens). `phoenix_kit_warehouse_stock.quantity`
  is an unbounded `NUMERIC`, so this cap is the only thing between an API
  caller and a stock row of astronomic size.

  Quantities leave the API as decimal strings with the padding zeros removed
  (`format/1`).
  """

  alias PhoenixKitWarehouse.StockLedger

  @max Decimal.new("1000000000")
  @max_places 6
  @plain ~r/\A\d{1,10}(\.\d{1,6})?\z/

  @type minimum :: :zero | :positive

  @doc """
  Parses `value`. With `minimum: :positive` zero is refused as well.

  Returns `{:ok, decimal}` or `{:error, message}` (English, written to be
  shown next to the field).
  """
  @spec parse(term(), minimum()) :: {:ok, Decimal.t()} | {:error, String.t()}
  def parse(value, minimum \\ :zero)

  def parse(value, minimum) when is_binary(value) do
    if Regex.match?(@plain, value) do
      value |> Decimal.new() |> check(minimum)
    else
      {:error,
       "must be a plain decimal such as \"12\" or \"0.5\" (up to 6 decimal places, no sign, no exponent)"}
    end
  end

  def parse(value, _minimum) when is_integer(value) and value < 0,
    do: {:error, "must not be negative"}

  def parse(value, minimum) when is_integer(value), do: value |> Decimal.new() |> check(minimum)

  def parse(value, minimum) when is_float(value),
    do: value |> Decimal.from_float() |> check(minimum)

  def parse(_value, _minimum),
    do: {:error, "must be a number or a plain decimal string such as \"12\" or \"0.5\""}

  defp check(%Decimal{} = number, minimum) do
    number = if Decimal.eq?(number, 0), do: Decimal.new(0), else: number

    cond do
      Decimal.negative?(number) -> {:error, "must not be negative"}
      Decimal.gt?(number, @max) -> {:error, "must be at most 1000000000"}
      places(number) > @max_places -> {:error, "must have at most 6 decimal places"}
      minimum == :positive and Decimal.eq?(number, 0) -> {:error, "must be greater than zero"}
      true -> {:ok, number}
    end
  end

  defp places(%Decimal{exp: exp}) when exp < 0, do: -exp
  defp places(%Decimal{}), do: 0

  @doc """
  Renders a quantity (a `Decimal`, a stored string, a number) without padding
  zeros: `5.000000 -> "5"`, `1.500000 -> "1.5"`, `0.000000 -> "0"`.
  """
  @spec format(Decimal.t() | String.t() | number() | nil) :: String.t()
  def format(value), do: StockLedger.format_quantity(value)

  @doc "Like `format/1`, but `nil` stays `nil` (a unit value that was never set)."
  @spec format_optional(Decimal.t() | String.t() | number() | nil) :: String.t() | nil
  def format_optional(nil), do: nil
  def format_optional(value), do: format(value)

  @doc """
  The plain-notation string a posting function takes as a line quantity
  (`Decimal.to_string(number, :normal)`, never an exponent form).
  """
  @spec to_param(Decimal.t()) :: String.t()
  def to_param(%Decimal{} = number), do: Decimal.to_string(number, :normal)
end
