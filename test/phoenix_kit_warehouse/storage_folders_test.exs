defmodule PhoenixKitWarehouse.StorageFoldersTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.StorageFolders
  alias PhoenixKitWarehouse.SupplierOrders

  defmodule Hook do
    @moduledoc false
    def parent(:supplier_order, _actor), do: {:ok, Process.get(:supplier_orders_container)}
    def parent(_, _), do: nil
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :storage_parent_folder) end)
    :ok
  end

  defp default_location_uuid, do: "00000000-0000-0000-0000-000000000001"

  defp create_supplier! do
    {:ok, supplier} =
      Catalogue.create_supplier(%{
        name: "Test Supplier #{System.unique_integer([:positive])}",
        status: "active"
      })

    supplier
  end

  defp create_supplier_order! do
    supplier = create_supplier!()

    {:ok, order} =
      SupplierOrders.create_supplier_order(%{
        supplier_uuid: supplier.uuid,
        location_uuid: default_location_uuid()
      })

    order
  end

  defp container!(name) do
    {:ok, folder} = Storage.create_folder(%{name: name})
    folder
  end

  test "without config the folder is created at root (legacy behaviour)" do
    order = create_supplier_order!()

    assert {:ok, %Folder{parent_uuid: nil, name: name}} =
             StorageFolders.ensure_for_supplier_order(order, nil)

    assert name == "supplier-order-#{order.number}"
  end

  test "with config the folder is created under the configured parent" do
    container = container!("Supplier orders")
    Process.put(:supplier_orders_container, container.uuid)
    Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {Hook, :parent})

    order = create_supplier_order!()

    assert {:ok, %Folder{parent_uuid: parent}} =
             StorageFolders.ensure_for_supplier_order(order, nil)

    assert parent == container.uuid
    assert SupplierOrders.get_supplier_order!(order.uuid).storage_folder_uuid != nil
  end

  test "a legacy root folder is adopted under the parent and linked" do
    container = container!("Supplier orders")
    Process.put(:supplier_orders_container, container.uuid)
    Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {Hook, :parent})

    order = create_supplier_order!()
    name = "supplier-order-#{order.number}"
    {:ok, legacy} = Storage.create_folder(%{name: name})

    assert {:ok, %Folder{uuid: uuid}} = StorageFolders.ensure_for_supplier_order(order, nil)
    assert uuid == legacy.uuid
    assert Repo.get!(Folder, uuid).parent_uuid == container.uuid
    assert Repo.aggregate(from(f in Folder, where: f.name == ^name), :count) == 1
  end

  test "resources without a hook clause stay at root" do
    Application.put_env(:phoenix_kit_warehouse, :storage_parent_folder, {Hook, :parent})
    assert StorageFolders.parent_uuid_for(:goods_issue, nil) == nil
  end
end
