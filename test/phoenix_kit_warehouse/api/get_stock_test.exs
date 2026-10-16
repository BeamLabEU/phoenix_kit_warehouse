defmodule PhoenixKitWarehouse.API.GetStockTest do
  @moduledoc "`warehouse.get_stock`: per-location quantities and totals, row errors in place."
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKitWarehouse.API.Stock
  alias PhoenixKitWarehouse.StockLedger

  setup do
    %{locations: [first, second]} = warehouses!(2)
    catalogue = shop_catalogue!()
    %{first: first, second: second, catalogue: catalogue, ctx: ctx(user!())}
  end

  defp call(input, ctx), do: Stock.get_stock(input, ctx)

  test "lists every location with a row and the total", %{
    first: first,
    second: second,
    catalogue: catalogue,
    ctx: ctx
  } do
    item = item!(catalogue)
    seed!(item.uuid, "10", first.uuid)
    seed!(item.uuid, "2.5", second.uuid)

    {:ok, _} =
      StockLedger.upsert_quantity(item.uuid, Decimal.new("10"),
        location_uuid: first.uuid,
        unit_value: Decimal.new("1.250000")
      )

    ref = %{"id" => item.uuid}
    assert {:ok, %{"results" => [result]}} = call(%{"refs" => [ref]}, ctx)

    assert %{
             "ref" => ^ref,
             "id" => id,
             "sku" => sku,
             "name" => name,
             "unit" => unit,
             "total" => "12.5",
             "locations" => locations
           } = result

    assert {id, sku, name, unit} == {item.uuid, item.sku, item.name, item.unit}

    by_location = Map.new(locations, &{&1["location_id"], &1})

    assert %{"quantity" => "10", "unit_value" => "1.25", "name" => first_name} =
             by_location[first.uuid]

    assert first_name == first.name
    assert %{"quantity" => "2.5", "unit_value" => nil} = by_location[second.uuid]
  end

  test "a product with no stock rows has no locations and a zero total", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    item = item!(catalogue)

    assert {:ok, %{"results" => [%{"locations" => [], "total" => "0"}]}} =
             call(%{"refs" => [%{"id" => item.uuid}]}, ctx)
  end

  test "with location_id only that location is listed, with 0 when there is no row", %{
    first: first,
    second: second,
    catalogue: catalogue,
    ctx: ctx
  } do
    item = item!(catalogue)
    seed!(item.uuid, "4", first.uuid)

    assert {:ok, %{"results" => [%{"locations" => [only], "total" => "0"}]}} =
             call(%{"refs" => [%{"id" => item.uuid}], "location_id" => second.uuid}, ctx)

    assert only["location_id"] == second.uuid
    assert only["quantity"] == "0"

    assert {:ok, %{"results" => [%{"locations" => [one], "total" => "4"}]}} =
             call(%{"refs" => [%{"id" => item.uuid}], "location_id" => first.uuid}, ctx)

    assert one["quantity"] == "4"
  end

  test "row errors stay in place and do not stop the other rows", %{
    first: first,
    catalogue: catalogue,
    ctx: ctx
  } do
    item = item!(catalogue)
    seed!(item.uuid, "1", first.uuid)
    bad = %{"id" => Ecto.UUID.generate()}

    assert {:ok, %{"results" => [good, missing, malformed]}} =
             call(%{"refs" => [%{"id" => item.uuid}, bad, %{"sku" => "  "}]}, ctx)

    assert good["id"] == item.uuid
    assert %{"ref" => ^bad, "error" => %{"code" => "not_found"}} = missing
    assert %{"error" => %{"code" => "validation_failed"}} = malformed
  end

  test "the same product listed twice is answered twice (a read)", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    item = item!(catalogue)
    ref = %{"id" => item.uuid}
    assert {:ok, %{"results" => [a, b]}} = call(%{"refs" => [ref, ref]}, ctx)
    assert a == b
  end

  test "catalogue_id narrows the refs; an unknown one is a top-level validation_failed", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    item = item!(catalogue)
    other = catalogue!()

    assert {:ok, %{"results" => [%{"error" => %{"code" => "not_found"}}]}} =
             call(%{"refs" => [%{"id" => item.uuid}], "catalogue_id" => other.uuid}, ctx)

    assert {:error, :validation_failed, _message, %{errors: [%{path: "catalogue_id"}]}} =
             call(
               %{"refs" => [%{"id" => item.uuid}], "catalogue_id" => Ecto.UUID.generate()},
               ctx
             )
  end

  test "with two active catalogues catalogue_id is required", %{catalogue: catalogue, ctx: ctx} do
    item = item!(catalogue)
    _other = catalogue!()

    assert {:error, :validation_failed, _message,
            %{errors: [%{path: "catalogue_id", code: "validation_failed"}]}} =
             call(%{"refs" => [%{"id" => item.uuid}]}, ctx)

    assert {:ok, %{"results" => [%{"id" => id}]}} =
             call(%{"refs" => [%{"id" => item.uuid}], "catalogue_id" => catalogue.uuid}, ctx)

    assert id == item.uuid
  end

  test "the stock of an archived catalogue's item can be read, a deleted catalogue is refused", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    item = item!(catalogue)
    input = %{"refs" => [%{"id" => item.uuid}], "catalogue_id" => catalogue.uuid}

    set_catalogue_status!(catalogue, "archived")
    assert {:ok, %{"results" => [%{"id" => id}]}} = call(input, ctx)
    assert id == item.uuid

    set_catalogue_status!(catalogue, "deleted")

    assert {:error, :validation_failed, _message, %{errors: [%{path: "catalogue_id"}]}} =
             call(input, ctx)
  end

  if Code.ensure_loaded?(PhoenixKitCatalogue.API) and
       function_exported?(PhoenixKitCatalogue.API, :resolve_refs, 2) do
    test "an ambiguous sku is a row error with its candidates; the other rows are answered", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      one = item!(catalogue, %{sku: "TWIN-STOCK"})
      two = item!(catalogue, %{sku: "TWIN-STOCK"})
      good = item!(catalogue)

      assert {:ok, %{"results" => [ambiguous, found]}} =
               call(%{"refs" => [%{"sku" => "TWIN-STOCK"}, %{"id" => good.uuid}]}, ctx)

      assert %{"error" => %{"code" => "ambiguous_ref", "candidates" => candidates}} = ambiguous
      assert Enum.sort(candidates) == Enum.sort([one.uuid, two.uuid])
      assert found["id"] == good.uuid
    end
  end

  test "a location_id that is not a warehouse is a top-level validation_failed", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    item = item!(catalogue)

    assert {:error, :validation_failed, _message,
            %{errors: [%{path: "location_id", code: "validation_failed"}]}} =
             call(%{"refs" => [%{"id" => item.uuid}], "location_id" => Ecto.UUID.generate()}, ctx)
  end

  test "refs that is missing or not a list is a top-level validation_failed", %{ctx: ctx} do
    for input <- [%{}, %{"refs" => nil}, %{"refs" => "x"}, %{"refs" => %{}}] do
      assert {:error, :validation_failed, _message,
              %{errors: [%{path: "refs", code: "validation_failed"}]}} = call(input, ctx),
             inspect(input)
    end
  end

  test "reading writes nothing", %{catalogue: catalogue, ctx: ctx} do
    item = item!(catalogue)
    before = Repo.aggregate(PhoenixKitWarehouse.Stock, :count)
    call(%{"refs" => [%{"id" => item.uuid}]}, ctx)
    assert Repo.aggregate(PhoenixKitWarehouse.Stock, :count) == before
  end
end
