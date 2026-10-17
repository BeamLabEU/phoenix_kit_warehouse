defmodule PhoenixKitWarehouse.API.Lines do
  @moduledoc """
  Prepares the `lines` of a warehouse document tool: resolves every product
  ref to a live catalogue item, reads every quantity (and unit value),
  and refuses a product that appears on more than one line.

  Nothing here writes. Every problem of every line is collected, so a caller
  fixes the whole request in one pass; the document tools post nothing when
  the list of errors is not empty (warehouse documents are atomic).
  """

  alias PhoenixKitWarehouse.API.Quantity
  alias PhoenixKitWarehouse.API.Refs

  @type line :: %{
          index: non_neg_integer(),
          ref: term(),
          item: Refs.resolved(),
          quantity: Decimal.t(),
          unit_value: Decimal.t() | nil
        }
  @type error :: %{
          required(:path) => String.t(),
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(:candidates) => [String.t()],
          optional(:first_line) => non_neg_integer()
        }

  @doc """
  Options: `:minimum` (`:zero | :positive`, required), `:unit_value`
  (read each line's `"unit_value"`, default `false`), `:catalogue_uuid`.
  """
  @spec prepare(term(), keyword()) :: {:ok, [line()]} | {:error, [error()]}
  def prepare(raw_lines, opts) when is_list(raw_lines) and raw_lines != [] do
    resolved =
      raw_lines
      |> Enum.map(&line_ref/1)
      |> Refs.resolve(catalogue_uuid: Keyword.get(opts, :catalogue_uuid), write: true)

    prepare_resolved(raw_lines, resolved, opts)
  end

  def prepare(_other, _opts) do
    {:error,
     [%{path: "lines", code: "validation_failed", message: "lines must be a non-empty list."}]}
  end

  # Retries can recover missing product identities from the posted document.
  # They must still use the same quantity and duplicate validation as a new call.
  @doc false
  @spec prepare_resolved([term()], [{:ok, map()} | {:error, Refs.row_error()}], keyword()) ::
          {:ok, [line()]} | {:error, [error()]}
  def prepare_resolved(raw_lines, resolved, opts) do
    minimum = Keyword.fetch!(opts, :minimum)
    unit_value? = Keyword.get(opts, :unit_value, false)

    checked =
      raw_lines
      |> Enum.with_index()
      |> Enum.zip(resolved)
      |> Enum.map(fn {{raw, index}, resolution} ->
        check(raw, index, resolution, minimum, unit_value?)
      end)

    lines = for {:ok, line} <- checked, do: line

    errors =
      Enum.flat_map(checked, fn
        {:error, errors} -> errors
        {:ok, _line} -> []
      end)

    case errors ++ duplicates(resolved) do
      [] -> {:ok, lines}
      all -> {:error, Enum.sort_by(all, &error_index/1)}
    end
  end

  defp line_ref(%{} = line) when not is_struct(line), do: Map.get(line, "ref")
  defp line_ref(_other), do: nil

  defp check(raw, index, _resolution, _minimum, _unit_value?)
       when not is_map(raw) or is_struct(raw) do
    {:error,
     [
       %{
         path: "lines[#{index}]",
         code: "validation_failed",
         message: "A line is an object with ref and quantity."
       }
     ]}
  end

  defp check(raw, index, resolution, minimum, unit_value?) do
    path = "lines[#{index}]"
    quantity = Quantity.parse(Map.get(raw, "quantity"), minimum)
    unit_value = unit_value(raw, unit_value?)

    errors =
      [ref: resolution, quantity: quantity, unit_value: unit_value]
      |> Enum.flat_map(fn
        {field, {:error, detail}} -> [field_error(path, field, detail)]
        {_field, {:ok, _value}} -> []
      end)

    with [] <- errors,
         {:ok, item} <- resolution,
         {:ok, parsed_quantity} <- quantity,
         {:ok, parsed_unit_value} <- unit_value do
      {:ok,
       %{
         index: index,
         ref: Map.get(raw, "ref"),
         item: item,
         quantity: parsed_quantity,
         unit_value: parsed_unit_value
       }}
    else
      _failed -> {:error, errors}
    end
  end

  defp unit_value(raw, true) do
    case Map.get(raw, "unit_value") do
      nil -> {:ok, nil}
      value -> Quantity.parse(value, :zero)
    end
  end

  defp unit_value(_raw, false), do: {:ok, nil}

  defp field_error(path, :ref, %{code: code, message: message} = detail) do
    detail
    |> Map.take([:candidates])
    |> Map.merge(%{path: path <> ".ref", code: code, message: message})
  end

  defp field_error(path, field, message) when is_binary(message) do
    %{path: "#{path}.#{field}", code: "validation_failed", message: message}
  end

  # Judged on the resolved item, so differently spelled refs to one product
  # are caught, and a line whose quantity is wrong is still checked. The first
  # line keeps the product; every later one is refused.
  defp duplicates(resolved) do
    resolved
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:ok, item}, index} -> [{item.uuid, index}]
      {{:error, _error}, _index} -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {_uuid, [first | rest]} ->
      Enum.map(rest, fn index ->
        %{
          path: "lines[#{index}]",
          code: "duplicate_line",
          message:
            "This product is already on lines[#{first}]; put the whole quantity on one line.",
          first_line: first
        }
      end)
    end)
  end

  defp error_index(%{path: path}) do
    case Regex.run(~r/\Alines\[(\d+)\]/, path) do
      [_whole, index] -> String.to_integer(index)
      _none -> 0
    end
  end
end
