defmodule PhoenixKitWarehouse.InventoryAI.CatalogueListTest do
  # The catalogue the model chooses from (spec §7): every live active goods
  # item, numbered, a star for the items the warehouse holds, no stock
  # quantities, narrowed by catalogues, refused past the limit.
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitWarehouse.InventoryAI.CatalogueList
  alias PhoenixKitWarehouse.StockLedger

  defp catalogue!(attrs \\ %{}) do
    {:ok, catalogue} =
      Catalogue.create_catalogue(
        Map.merge(%{name: "Cat #{System.unique_integer([:positive])}"}, attrs)
      )

    catalogue
  end

  defp category!(catalogue, name, parent \\ nil) do
    {:ok, category} =
      Catalogue.create_category(%{
        name: name,
        catalogue_uuid: catalogue.uuid,
        parent_uuid: parent && parent.uuid
      })

    category
  end

  defp item!(catalogue, attrs) do
    {:ok, item} =
      Catalogue.create_item(
        Map.merge(
          %{
            name: "Item #{System.unique_integer([:positive])}",
            catalogue_uuid: catalogue.uuid,
            status: "active",
            unit: "piece"
          },
          attrs
        )
      )

    item
  end

  # Straight in the table: the catalogue's own updates keep a trash status
  # as it is, and its trash cascades to the children - here a parent is
  # deleted while its child is not.
  defp mark_deleted(schema, record) do
    {1, _} =
      Repo.update_all(from(r in schema, where: r.uuid == ^record.uuid), set: [status: "deleted"])
  end

  defp lines(list), do: String.split(list.text, "\n", trim: true)

  setup do
    location = Ecto.UUID.generate()
    goods = catalogue!(%{name: "Fittings"})
    fasteners = category!(goods, "Fasteners")
    screws = category!(goods, "Screws", fasteners)

    hinge = item!(goods, %{name: "Hinge 110", sku: "H-110", category_uuid: fasteners.uuid})
    screw = item!(goods, %{name: "Screw 4x30", sku: "S-430", category_uuid: screws.uuid})
    loose = item!(goods, %{name: "Loose item", sku: nil})

    {:ok, _} = StockLedger.upsert_quantity(screw.uuid, "512", location_uuid: location)

    %{
      location: location,
      goods: goods,
      fasteners: fasteners,
      screws: screws,
      hinge: hinge,
      screw: screw,
      loose: loose
    }
  end

  test "one numbered line per item: No|name|sku|unit|catalogue > category path", ctx do
    {:ok, list} = CatalogueList.build(ctx.location, catalogue_uuids: [ctx.goods.uuid])

    assert list.count == 3
    assert MapSet.equal?(list.numbers, MapSet.new(1..3))

    assert lines(list) == [
             "1|Loose item||piece|Fittings",
             "2|Hinge 110|H-110|piece|Fittings > Fasteners",
             "★3|Screw 4x30|S-430|piece|Fittings > Fasteners > Screws"
           ]
  end

  test "the map from numbers to items, and each number's catalogue facts", ctx do
    {:ok, list} = CatalogueList.build(ctx.location, catalogue_uuids: [ctx.goods.uuid])

    assert list.catalogue_map == %{
             "1" => ctx.loose.uuid,
             "2" => ctx.hinge.uuid,
             "3" => ctx.screw.uuid
           }

    assert %{
             "no" => 3,
             "item_uuid" => screw_uuid,
             "name" => "Screw 4x30",
             "sku" => "S-430",
             "unit" => "piece",
             "catalogue_uuid" => catalogue_uuid,
             "category_uuid" => category_uuid,
             "path" => "Fittings > Fasteners > Screws",
             "starred" => true
           } = list.items[3]

    assert screw_uuid == ctx.screw.uuid
    assert catalogue_uuid == ctx.goods.uuid
    assert category_uuid == ctx.screws.uuid
    assert list.items[2]["starred"] == false
  end

  test "the stock's quantity is not in the request", ctx do
    {:ok, list} = CatalogueList.build(ctx.location, catalogue_uuids: [ctx.goods.uuid])
    refute list.text =~ "512"
  end

  test "the star is for the document's warehouse only", ctx do
    {:ok, list} = CatalogueList.build(Ecto.UUID.generate(), catalogue_uuids: [ctx.goods.uuid])
    refute list.text =~ "★"
  end

  test "only active goods of live catalogues and categories", ctx do
    item!(ctx.goods, %{name: "Inactive", status: "inactive"})
    item!(ctx.goods, %{name: "Discontinued", status: "discontinued"})
    item!(ctx.goods, %{name: "Own service", item_type: "service"})

    services = catalogue!(%{name: "Services", item_type: "service"})
    item!(services, %{name: "Assembly", unit: "hour"})
    item!(services, %{name: "Goods in a service catalogue", item_type: "goods"})

    gone = category!(ctx.goods, "Gone")
    item!(ctx.goods, %{name: "In a deleted category", category_uuid: gone.uuid})
    mark_deleted(Category, gone)

    old = category!(ctx.goods, "Old")
    child = category!(ctx.goods, "Child of old", old)
    item!(ctx.goods, %{name: "Under a deleted parent", category_uuid: child.uuid})
    mark_deleted(Category, old)

    dead = catalogue!(%{name: "Dead"})
    item!(dead, %{name: "In a deleted catalogue"})
    mark_deleted(CatalogueSchema, dead)

    {:ok, list} =
      CatalogueList.build(ctx.location,
        catalogue_uuids: [ctx.goods.uuid, services.uuid, dead.uuid]
      )

    names = list.items |> Map.values() |> Enum.map(& &1["name"]) |> Enum.sort()

    assert names ==
             Enum.sort(["Loose item", "Hinge 110", "Screw 4x30", "Goods in a service catalogue"])
  end

  test "narrowed to the chosen catalogues; none chosen is every catalogue", ctx do
    other = catalogue!(%{name: "Boards"})
    board = item!(other, %{name: "Board 18mm", unit: "m2"})

    {:ok, narrowed} = CatalogueList.build(ctx.location, catalogue_uuids: [other.uuid])
    assert Map.values(narrowed.catalogue_map) == [board.uuid]
    assert lines(narrowed) == ["1|Board 18mm||m2|Boards"]

    {:ok, all} = CatalogueList.build(ctx.location, catalogue_uuids: [])
    uuids = Map.values(all.catalogue_map)
    assert board.uuid in uuids and ctx.hinge.uuid in uuids
  end

  test "a | or a line break in a name cannot break the line", ctx do
    item!(ctx.goods, %{name: "Odd | name\nwith a break", sku: "A|B"})

    {:ok, list} = CatalogueList.build(ctx.location, catalogue_uuids: [ctx.goods.uuid])

    assert Enum.any?(lines(list), &(&1 =~ "|Odd / name with a break|A/B|piece|Fittings"))
    assert length(lines(list)) == 4
  end

  test "past max_items the list is refused, with the count", ctx do
    assert CatalogueList.build(ctx.location, catalogue_uuids: [ctx.goods.uuid], max_items: 2) ==
             {:error, {:too_many_items, 3, 2}}

    assert {:ok, _} =
             CatalogueList.build(ctx.location, catalogue_uuids: [ctx.goods.uuid], max_items: 3)

    assert CatalogueList.count(catalogue_uuids: [ctx.goods.uuid]) == 3
  end

  test "an empty catalogue is an empty list, not an error", ctx do
    empty = catalogue!()

    assert {:ok, %{count: 0, text: "", catalogue_map: map}} =
             CatalogueList.build(ctx.location, catalogue_uuids: [empty.uuid])

    assert map == %{}
  end
end
