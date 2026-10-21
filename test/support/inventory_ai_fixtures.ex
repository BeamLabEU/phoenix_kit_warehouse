defmodule PhoenixKitWarehouse.Test.InventoryAIFixtures do
  @moduledoc """
  Fixtures of the photo inventory tests: a user, a catalogue with items and
  stock, a draft, the AI switched on with an endpoint chosen, photos to
  retrieve, the model's answer and a proposed run.
  """

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryAI.CatalogueList
  alias PhoenixKitWarehouse.InventoryAI.Proposal
  alias PhoenixKitWarehouse.InventoryAI.Response
  alias PhoenixKitWarehouse.InventoryAI.Settings
  alias PhoenixKitWarehouse.InventoryAIRun
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.StorageFolders

  @fixtures Path.expand("../fixtures/inventory_ai", __DIR__)

  def user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "invai-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Stock",
        "last_name" => "Taker"
      })

    user
  end

  @doc "The AI on, an endpoint chosen, the module's prompt cleared (made again on use)."
  def ai_ready! do
    {:ok, _} = PhoenixKitAI.enable_system()

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Vision #{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "google/gemini-flash",
        api_key: "test-key"
      })

    :ok = Settings.set_endpoint_uuid(endpoint.uuid)
    PhoenixKit.Settings.update_setting("warehouse_inventory_ai_prompt_uuid", "")
    endpoint
  end

  def catalogue!(name \\ nil) do
    {:ok, catalogue} =
      Catalogue.create_catalogue(%{
        name: name || "Fittings #{System.unique_integer([:positive])}"
      })

    catalogue
  end

  def item!(catalogue, attrs \\ %{}) do
    {:ok, item} =
      Catalogue.create_item(
        Map.merge(
          %{
            name: "Item #{System.unique_integer([:positive])}",
            catalogue_uuid: catalogue.uuid,
            status: "active",
            unit: "piece",
            base_price: "2.00"
          },
          attrs
        )
      )

    item
  end

  def stock!(item, location, quantity) do
    {:ok, _} = StockLedger.upsert_quantity(item.uuid, quantity, location_uuid: location)
  end

  @doc "A draft on `location`, seeded from its stock (or with `lines`)."
  def draft!(location, lines \\ nil) do
    {:ok, doc} =
      Inventories.create_draft(%{
        location_uuid: location,
        lines: lines || Inventories.seed_lines("en", location)
      })

    doc
  end

  @doc """
  `count` photos of `doc`: Storage files in the document's folder (the rows
  only - the bytes come through `retriever/1`), uploaded by `user`.
  """
  def photos!(doc, user, count \\ 2) do
    {:ok, folder} = StorageFolders.ensure_for_inventory(doc, user.uuid)
    for _ <- 1..count, do: storage_file!(folder.uuid, user).uuid
  end

  @doc "A Storage file row in `folder_uuid` (`nil` - in no folder)."
  def storage_file!(folder_uuid, user) do
    checksum = "invai-#{System.unique_integer([:positive])}"

    %Storage.File{}
    |> Storage.File.changeset(%{
      original_file_name: "shelf.heic",
      file_name: "shelf-#{checksum}.heic",
      mime_type: "image/heic",
      file_type: "image",
      ext: "heic",
      file_checksum: checksum,
      user_file_checksum: checksum,
      size: 984,
      status: "active",
      user_uuid: user.uuid,
      folder_uuid: folder_uuid
    })
    |> PhoenixKit.RepoHelper.repo().insert!()
  end

  @doc "A `:retrieve` for the photos: each uuid gets a temporary copy of a fixture."
  def retriever(photos \\ %{}) do
    fn uuid ->
      case Map.get(photos, uuid, :heic) do
        :heic -> copy(Path.join(@fixtures, "shelf.heic"), ".heic")
        :missing -> {:error, "File not found"}
        path -> copy(path, Path.extname(path))
      end
    end
  end

  defp copy(source, ext) do
    target =
      Path.join(System.tmp_dir!(), "invai-test-#{System.unique_integer([:positive])}#{ext}")

    File.cp!(source, target)
    {:ok, target, %{}}
  end

  def object(attrs \\ %{}) do
    Map.merge(
      %{
        "object_key" => "A",
        "photos" => [1],
        "description" => "Box",
        "catalogue_no" => 1,
        "alternatives" => [],
        "match_confidence" => "high",
        "package" => "box",
        "closed_packages" => 0,
        "open_packages" => 0,
        "open_fill" => nil,
        "units_per_package" => nil,
        "loose_units" => 10,
        "quantity" => nil,
        "count_confidence" => "high",
        "basis" => "counted"
      },
      attrs
    )
  end

  def answer(objects, attrs \\ %{}) do
    Map.merge(
      %{
        "off_purpose" => %{"flag" => false, "reason" => ""},
        "nothing_found" => false,
        "overlap" => "",
        "objects" => objects
      },
      attrs
    )
  end

  @doc """
  A proposed run of `doc`, as the task would leave it, for the model's
  `objects` over the catalogues `catalogue_uuids`.
  """
  def proposed_run!(doc, place, objects, catalogue_uuids, attrs \\ %{}) do
    {:ok, list} = CatalogueList.build(doc.location_uuid, catalogue_uuids: catalogue_uuids)

    {:ok, checked} =
      Response.check(answer(objects), %{photo_count: 3, numbers: list.numbers})

    repo = PhoenixKit.RepoHelper.repo()

    %InventoryAIRun{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          inventory_uuid: doc.uuid,
          location_uuid: doc.location_uuid,
          place_label: place,
          photo_file_uuids: [Ecto.UUID.generate()],
          status: "proposed",
          catalogue_map: list.catalogue_map,
          result: %{
            "catalogue_uuids" => catalogue_uuids,
            "rows" => Proposal.build(checked.objects, list.items)
          }
        },
        attrs
      )
    )
    |> repo.insert!()
    # Read back: the result as jsonb gives it, numbers as text.
    |> then(&repo.get!(InventoryAIRun, &1.uuid))
  end
end
