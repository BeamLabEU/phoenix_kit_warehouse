defmodule PhoenixKitWarehouse.LineExplanation do
  @moduledoc """
  The optional `"explanation"` key of a document line: free text, supplied by
  the host that built the line, saying why the item is there and where the
  quantity comes from.

  The module only carries it — from an internal order into a supplier order,
  and between lines of the same item that are merged — and shows it on the
  forms. Paragraphs are separated by a blank line; merging never repeats a
  paragraph.
  """

  @key "explanation"

  @doc "The explanation of a line, or `nil` when it has none."
  def get(line) when is_map(line) do
    case Map.get(line, @key) do
      text when is_binary(text) -> blank_to_nil(text)
      _ -> nil
    end
  end

  def get(_line), do: nil

  @doc "Whether any of the lines carries an explanation."
  def any?(lines) when is_list(lines), do: Enum.any?(lines, &(get(&1) != nil))
  def any?(_lines), do: false

  @doc """
  Combines two explanations (either may be `nil`) into one text without
  repeating a paragraph. Returns `nil` when both are empty.
  """
  def merge(a, b) do
    [a, b]
    |> Enum.flat_map(&paragraphs/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      list -> Enum.join(list, "\n\n")
    end
  end

  @doc "Sets the line's explanation; a `nil` text leaves the line without the key."
  def put(line, nil), do: Map.delete(line, @key)
  def put(line, text), do: Map.put(line, @key, text)

  @doc "Copies the explanation of `source` into `line` (nothing when `source` has none)."
  def carry(line, source), do: put(line, get(source))

  @doc """
  Merges the explanations of `target` and `source` into `target`. A `source`
  without one leaves `target` as it is.
  """
  def merge_into(target, source) do
    case get(source) do
      nil -> target
      text -> put(target, merge(get(target), text))
    end
  end

  defp paragraphs(text) when is_binary(text) do
    text
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp paragraphs(_), do: []

  defp blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: text)
end
