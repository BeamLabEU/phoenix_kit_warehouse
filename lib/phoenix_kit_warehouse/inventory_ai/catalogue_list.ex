defmodule PhoenixKitWarehouse.InventoryAI.CatalogueList do
  @moduledoc """
  The catalogue the photo inventory's model chooses from (spec §7): the
  whole live catalogue in one compact block, one line per item.

      No|name|sku|unit|catalogue > category path
      ★12|Screw 4x30|S-430|piece|Fittings > Fasteners > Screws

  * The items: `status "active"`, of the effective type `goods` (the item's
    own type, else its catalogue's), in catalogues and categories that are
    not deleted - a category under a deleted parent included. Categories
    hidden from customers (`internal`) are not left out: fasteners live
    there. The name is the item's own (`name`), the catalogue's main
    language.
  * Short numbers instead of uuids: cheaper, and nothing for the model to
    make up. `catalogue_map` (`"No" => item_uuid`) is kept in the run.
  * Order: catalogue, then category path, then the catalogue's own order.
  * A star for an item with a stock row on the document's warehouse. The
    stock's quantity is never sent, so that the model does not count
    towards it.
  * Narrowed by `catalogue_uuids:` (none or `[]` is every catalogue), and
    refused past `max_items:` (the setting by default).
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitWarehouse.InventoryAI.Settings
  alias PhoenixKitWarehouse.StockLedger

  @max_depth 32

  @type t :: %{
          text: String.t(),
          count: non_neg_integer(),
          numbers: MapSet.t(pos_integer()),
          items: %{pos_integer() => map()},
          catalogue_map: %{String.t() => String.t()}
        }

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "How many items the list for `catalogue_uuids:` would carry, at most."
  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []), do: Catalogue.count_search_items("", search_opts(opts))

  @doc """
  The list for a document on `location_uuid`: `{:ok, list}`, or
  `{:error, {:too_many_items, count, max}}` while the chosen catalogues hold
  more items than `max_items`.
  """
  @spec build(Ecto.UUID.t(), keyword()) ::
          {:ok, t()} | {:error, {:too_many_items, non_neg_integer(), pos_integer()}}
  def build(location_uuid, opts \\ []) do
    max = Keyword.get_lazy(opts, :max_items, &Settings.max_items/0)

    case count(opts) do
      count when count > max ->
        {:error, {:too_many_items, count, max}}

      0 ->
        {:ok, numbered([])}

      count ->
        stock = StockLedger.stock_map_for_location(location_uuid)

        ""
        |> Catalogue.search_items(Keyword.put(search_opts(opts), :limit, count))
        |> describe(stock)
        |> numbered()
        |> then(&{:ok, &1})
    end
  end

  defp search_opts(opts) do
    [
      catalogue_uuids: Keyword.get(opts, :catalogue_uuids) || [],
      statuses: ["active"],
      item_types: ["goods"],
      order: :position
    ]
  end

  # Each item with its catalogue's name and category path; items under a
  # deleted category (at any depth) are dropped.
  defp describe(items, stock) do
    categories = categories_of(items)

    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      case category_path(item.category_uuid, categories) do
        :deleted ->
          []

        path ->
          catalogue = item.catalogue

          [
            %{
              index: index,
              catalogue_uuid: item.catalogue_uuid,
              info: %{
                "item_uuid" => item.uuid,
                "name" => clean(item.name),
                "sku" => clean(item.sku),
                "unit" => item.unit,
                "catalogue_uuid" => item.catalogue_uuid,
                "category_uuid" => item.category_uuid,
                "path" => Enum.join([clean(catalogue && catalogue.name) | path], " > "),
                "starred" => Map.has_key?(stock, item.uuid)
              }
            }
          ]
      end
    end)
    |> sort()
  end

  # Catalogue in the catalogue's own order, then the category path, then the
  # item's place in the catalogue's order.
  defp sort(entries) do
    catalogue_rank =
      entries
      |> Enum.map(& &1.catalogue_uuid)
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new()

    Enum.sort_by(entries, fn entry ->
      {catalogue_rank[entry.catalogue_uuid], String.downcase(entry.info["path"]), entry.index}
    end)
  end

  defp numbered(entries) do
    items =
      entries
      |> Enum.with_index(1)
      |> Map.new(fn {entry, no} -> {no, Map.put(entry.info, "no", no)} end)

    numbers = items |> Map.keys() |> Enum.sort()

    %{
      text: Enum.map_join(numbers, "\n", &line(items[&1])),
      count: length(numbers),
      numbers: MapSet.new(numbers),
      items: items,
      catalogue_map:
        Map.new(items, fn {no, info} -> {Integer.to_string(no), info["item_uuid"]} end)
    }
  end

  defp line(info) do
    star = if info["starred"], do: "★", else: ""
    "#{star}#{info["no"]}|#{info["name"]}|#{info["sku"]}|#{info["unit"]}|#{info["path"]}"
  end

  defp categories_of(items) do
    catalogue_uuids = items |> Enum.map(& &1.catalogue_uuid) |> Enum.uniq()

    from(c in Category,
      where: c.catalogue_uuid in ^catalogue_uuids,
      select: {c.uuid, %{name: c.name, parent_uuid: c.parent_uuid, status: c.status}}
    )
    |> repo().all()
    |> Map.new()
  end

  # The names from the root down, or `:deleted` when the category or one of
  # its parents is.
  defp category_path(nil, _categories), do: []
  defp category_path(uuid, categories), do: category_path(uuid, categories, [], @max_depth)

  defp category_path(nil, _categories, path, _depth), do: path
  defp category_path(_uuid, _categories, path, 0), do: path

  defp category_path(uuid, categories, path, depth) do
    case categories[uuid] do
      nil ->
        path

      %{status: "deleted"} ->
        :deleted

      category ->
        category_path(category.parent_uuid, categories, [clean(category.name) | path], depth - 1)
    end
  end

  # A `|` or a line break in a catalogue text would break the line apart.
  defp clean(nil), do: ""

  defp clean(text) when is_binary(text) do
    text
    |> String.replace("|", "/")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
