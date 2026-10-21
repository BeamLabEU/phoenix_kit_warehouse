defmodule PhoenixKitWarehouse.InventoryAI.PhotoStoreTest do
  # An uploaded photo of the photo inventory goes into the document's Storage
  # folder (spec §5.3, §10.1): the folder made on first use, the file the
  # person's, visible on the Files tab, one of the photos start_run takes.
  use PhoenixKitWarehouse.DataCase, async: false

  # Storage says it cannot queue the variants: there is no Oban in the suite.
  @moduletag :capture_log

  import PhoenixKitWarehouse.Test.InventoryAIFixtures

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryAI

  @fixture Path.expand("../../fixtures/inventory_ai/shelf.heic", __DIR__)

  setup do
    local_bucket!()
    %{user: user!(), doc: draft!(Ecto.UUID.generate(), [])}
  end

  defp upload(name \\ "shelf.heic") do
    path = Path.join(System.tmp_dir!(), "pkw-upload-#{System.unique_integer([:positive])}")
    File.cp!(@fixture, path)
    on_exit(fn -> File.rm(path) end)
    %{path: path, client_name: name, client_type: "image/heic"}
  end

  test "the photo is stored in the document's folder, made on first use", ctx do
    assert ctx.doc.storage_folder_uuid == nil

    assert {:ok, file} = InventoryAI.store_photo(ctx.doc, upload(), ctx.user)

    folder = Inventories.get_document!(ctx.doc.uuid).storage_folder_uuid
    assert folder
    assert file.folder_uuid == folder
    assert file.user_uuid == ctx.user.uuid
    assert file.original_file_name == "shelf.heic"
    assert Storage.get_file(file.uuid)
  end

  test "the same photo again is the same file, still in the folder", ctx do
    {:ok, first} = InventoryAI.store_photo(ctx.doc, upload(), ctx.user)
    {:ok, again} = InventoryAI.store_photo(ctx.doc, upload("again.heic"), ctx.user)

    assert again.uuid == first.uuid
  end
end
