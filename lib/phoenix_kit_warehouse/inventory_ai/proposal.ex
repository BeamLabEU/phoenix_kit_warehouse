defmodule PhoenixKitWarehouse.InventoryAI.Proposal do
  @moduledoc """
  The rows of a run's proposal, built from the checked objects
  (`PhoenixKitWarehouse.InventoryAI.Response`) and the numbered catalogue
  (`PhoenixKitWarehouse.InventoryAI.CatalogueList`).

  One row per catalogue item: several objects of one item in a batch are one
  row, their counts summed (spec §6.4), each object's formula kept for "how
  it was counted". An object without an item is a row of its own, waiting
  for a person to choose one. The item's name, unit, catalogue and category
  are the catalogue's, never the model's.

  A row (string keys, stored in the run's `result`):

    * `"row"` - its number in the proposal, from 1;
    * `"catalogue_no"`, `"item"` (the catalogue facts, `nil` without one),
      `"alternatives"` (catalogue facts);
    * `"object_keys"`, `"photos"`, `"description"`, `"ai_basis"` (the model's
      words), `"objects"` (the checked objects);
    * `"match_confidence"`, `"count_confidence"` - the weakest of its objects;
    * `"count"` - `%{"kind", "quantity", "formulas"}`, `kind` one of
      `"counted"`, `"measured"`, `"package_size"` (the units per package or
      the quantity to be typed), `"quantity"` (to be typed), `"item"` (an
      item to be chosen first). While nothing is counted, `"formulas"` show
      what each object showed (`Counting.seen/1`), so a row is never blank.
  """

  alias PhoenixKitWarehouse.InventoryAI.Counting

  @confidence_rank %{"high" => 2, "medium" => 1, "low" => 0}
  @max_alternatives 3

  @doc "The rows for `objects`; `items` maps the catalogue numbers to their facts."
  @spec build([map()], %{pos_integer() => map()}) :: [map()]
  def build(objects, items) do
    objects
    |> group()
    |> Enum.with_index(1)
    |> Enum.map(fn {group, row} -> row(group, row, items) end)
  end

  @doc """
  The count of `row` for the item's `unit`, with the units per package a
  person typed (`nil` for none) - for a row whose item or package size was
  chosen in the table.
  """
  @spec recount(map(), String.t() | nil, Decimal.t() | nil) :: map()
  def recount(row, unit, package_size), do: count(row["objects"], unit, package_size)

  @doc "The count of a row whose item is still to be chosen: what its `objects` showed."
  @spec waiting_for_item([map()]) :: map()
  def waiting_for_item(objects),
    do: %{"kind" => "item", "quantity" => nil, "formulas" => seen(objects)}

  # Objects of one catalogue number together, in the order the first of each
  # came; an object without a number alone.
  defp group(objects) do
    {groups, order} =
      objects
      |> Enum.with_index()
      |> Enum.reduce({%{}, []}, fn {object, index}, {groups, order} ->
        key = if object["catalogue_no"], do: {:no, object["catalogue_no"]}, else: {:alone, index}

        if Map.has_key?(groups, key),
          do: {Map.update!(groups, key, &[object | &1]), order},
          else: {Map.put(groups, key, [object]), [key | order]}
      end)

    order |> Enum.reverse() |> Enum.map(&Enum.reverse(groups[&1]))
  end

  defp row([first | _] = objects, row, items) do
    no = first["catalogue_no"]
    item = no && items[no]

    %{
      "row" => row,
      "catalogue_no" => no,
      "item" => item,
      "alternatives" => alternatives(objects, no, items),
      "objects" => objects,
      "object_keys" => Enum.map(objects, & &1["object_key"]),
      "photos" => objects |> Enum.flat_map(& &1["photos"]) |> Enum.uniq() |> Enum.sort(),
      "description" => join(objects, "description"),
      "ai_basis" => join(objects, "basis"),
      "match_confidence" => weakest(objects, "match_confidence"),
      "count_confidence" => weakest(objects, "count_confidence"),
      "count" => if(item, do: count(objects, item["unit"], nil), else: waiting_for_item(objects))
    }
  end

  defp count(objects, unit, package_size) do
    case Counting.count_all(objects, unit, package_size) do
      {kind, quantity, formulas} ->
        %{"kind" => Atom.to_string(kind), "quantity" => quantity, "formulas" => formulas}

      {:needs, need} ->
        %{"kind" => Atom.to_string(need), "quantity" => nil, "formulas" => seen(objects)}
    end
  end

  defp seen(objects), do: objects |> Enum.map(&Counting.seen/1) |> Enum.reject(&is_nil/1)

  defp alternatives(objects, no, items) do
    objects
    |> Enum.flat_map(& &1["alternatives"])
    |> Enum.uniq()
    |> Enum.reject(&(&1 == no))
    |> Enum.flat_map(&List.wrap(items[&1]))
    |> Enum.take(@max_alternatives)
  end

  defp weakest(objects, key), do: Enum.min_by(objects, &@confidence_rank[&1[key]])[key]

  defp join(objects, key) do
    objects |> Enum.map(& &1[key]) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("; ")
  end
end
