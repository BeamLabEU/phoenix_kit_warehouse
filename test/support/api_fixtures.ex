defmodule PhoenixKitWarehouse.Test.ApiFixtures do
  @moduledoc """
  Fixtures of the warehouse API tests. Everything runs inside the sandbox
  transaction of the calling test (`PhoenixKitWarehouse.DataCase`), so
  nothing needs cleaning up.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.StockLedger

  @doc "A registered user (the owner of a key in real life)."
  def user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "api-wh-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Api",
        "last_name" => "Test"
      })

    user
  end

  @doc "A catalogue."
  def catalogue!(name \\ nil) do
    {:ok, catalogue} =
      Catalogue.create_catalogue(%{name: name || "API #{System.unique_integer([:positive])}"})

    catalogue
  end

  @doc """
  Archives every active catalogue, inside the test's transaction, so a test
  knows how many active catalogues exist (the scratch database may hold
  others).
  """
  def archive_all_catalogues! do
    repo().update_all(
      from(c in CatalogueSchema, where: c.status == "active"),
      set: [status: "archived"]
    )

    :ok
  end

  @doc """
  A catalogue that is the only active one. A handler called without
  `catalogue_id` works in it; with a second active catalogue it would refuse.
  """
  def shop_catalogue!(name \\ nil) do
    archive_all_catalogues!()
    catalogue!(name)
  end

  @doc """
  Sets the status of one catalogue row and nothing else. The catalogue API
  moves a catalogue's items together with it (`Catalogue.trash_catalogue/1`
  trashes them); this reaches the state "catalogue closed, item still live",
  which the checks of `Refs` exist for.
  """
  def set_catalogue_status!(catalogue, status) do
    repo().update_all(from(c in CatalogueSchema, where: c.uuid == ^catalogue.uuid),
      set: [status: status]
    )

    :ok
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "A catalogue item (active by default, with a unique sku)."
  def item!(catalogue, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, item} =
      Catalogue.create_item(
        Map.merge(
          %{
            name: "Item #{n}",
            catalogue_uuid: catalogue.uuid,
            base_price: "10.00",
            status: "active",
            sku: "API-#{n}"
          },
          attrs
        )
      )

    item
  end

  @doc """
  Configures the warehouse: a location type, `count` locations of that type
  (the first one is made the default warehouse). Returns
  `%{type: type, locations: [location]}`.
  """
  def warehouses!(count \\ 2) do
    {:ok, type} =
      Locations.create_location_type(%{name: "API WH #{System.unique_integer([:positive])}"})

    locations =
      for i <- 1..count do
        {:ok, location} =
          Locations.create_location(%{
            name: "API location #{i} #{System.unique_integer([:positive])}",
            status: "active"
          })

        Locations.sync_location_types(location.uuid, [type.uuid])
        location
      end

    StockLedger.set_warehouse_location_type_uuid(type.uuid)
    StockLedger.set_default_location_uuid(hd(locations).uuid)
    %{type: type, locations: locations}
  end

  @doc "Sets the stock of an item at a location (an absolute set, as a stocktake does)."
  def seed!(item_uuid, quantity, location_uuid) do
    {:ok, _} =
      StockLedger.upsert_quantity(item_uuid, Decimal.new(to_string(quantity)),
        location_uuid: location_uuid
      )

    :ok
  end

  @doc "The current quantity of an item at a location (a Decimal, 0 when there is no row)."
  def quantity(item_uuid, location_uuid), do: StockLedger.get_quantity(item_uuid, location_uuid)

  @doc """
  The `ctx` a handler receives from the executor, for a key owned by `user`.
  A plain map is used for the actor so handler tests do not depend on
  `PhoenixKit.API.Actor`; `Map.get/2` reads both.
  """
  def ctx(user, overrides \\ %{}) do
    actor = %{
      kind: :key,
      key_uuid: Ecto.UUID.generate(),
      key_prefix: "abcd1234",
      user_uuid: user.uuid,
      scopes: []
    }

    Map.merge(
      %{
        actor: actor,
        scopes: [],
        audience: :admin,
        language: "en",
        currency: nil,
        hosts: [],
        base_url: "http://localhost",
        request_id: "req-test",
        dry_run?: false
      },
      overrides
    )
  end
end
