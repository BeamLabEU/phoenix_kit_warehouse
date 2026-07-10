defmodule PhoenixKitWarehouse.StorageFolders do
  @moduledoc """
  Resolves (and creates if missing) the PhoenixKit Storage folder for a
  warehouse document.

  Consolidates what were 5 near-identical `*_storage_folders.ex` modules in
  Andi (`goods_issue_storage_folders.ex`, `goods_receipt_storage_folders.ex`,
  `inventory_storage_folders.ex`, `supplier_order_storage_folders.ex`,
  `internal_order_storage_folders.ex`) into one module with 5 `ensure_for_*/2`
  functions.

  Layout: a single, non-hierarchical folder at storage root, named
  `<prefix>-<number>` (falling back to `<prefix>-<uuid>` when the document
  has no number yet).

  Four of the five resources (goods issue, goods receipt, inventory, supplier
  order) cache the resolved folder's uuid on a `storage_folder_uuid` column
  and take a fast path once cached. The fifth — internal orders — has no
  `storage_folder_uuid` column at all (confirmed: `internal_order_storage_folders.ex`
  is a genuine smaller variant with a single function clause and no
  write-back) and resolves by name on every call instead.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder, as: StorageFolder
  alias PhoenixKitWarehouse.{GoodsIssue, GoodsIssues}
  alias PhoenixKitWarehouse.{GoodsReceipt, GoodsReceipts}
  alias PhoenixKitWarehouse.{InventoryDocument, Inventories}
  alias PhoenixKitWarehouse.{SupplierOrder, SupplierOrders}
  alias PhoenixKitWarehouse.InternalOrder

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Returns `{:ok, %Folder{}}` for the given goods issue, creating the folder
  if needed. Persists `storage_folder_uuid` on the issue record after first
  creation. Pass `admin_user_uuid` as the folder owner.
  """
  def ensure_for_goods_issue(issue, admin_user_uuid)

  def ensure_for_goods_issue(%GoodsIssue{storage_folder_uuid: uuid} = issue, admin_user_uuid)
      when not is_nil(uuid) do
    ensure_cached(issue, admin_user_uuid, "goods-issue", &GoodsIssues.set_storage_folder/2)
  end

  def ensure_for_goods_issue(%GoodsIssue{} = issue, admin_user_uuid) do
    create_and_cache(issue, admin_user_uuid, "goods-issue", &GoodsIssues.set_storage_folder/2)
  end

  @doc """
  Returns `{:ok, %Folder{}}` for the given goods receipt, creating the folder
  if needed. Persists `storage_folder_uuid` on the receipt record after first
  creation. Pass `admin_user_uuid` as the folder owner.
  """
  def ensure_for_goods_receipt(receipt, admin_user_uuid)

  def ensure_for_goods_receipt(
        %GoodsReceipt{storage_folder_uuid: uuid} = receipt,
        admin_user_uuid
      )
      when not is_nil(uuid) do
    ensure_cached(receipt, admin_user_uuid, "goods-receipt", &GoodsReceipts.set_storage_folder/2)
  end

  def ensure_for_goods_receipt(%GoodsReceipt{} = receipt, admin_user_uuid) do
    create_and_cache(
      receipt,
      admin_user_uuid,
      "goods-receipt",
      &GoodsReceipts.set_storage_folder/2
    )
  end

  @doc """
  Returns `{:ok, %Folder{}}` for the given inventory document, creating the
  folder if needed. Persists `storage_folder_uuid` on the document record
  after first creation. Pass `admin_user_uuid` as the folder owner.
  """
  def ensure_for_inventory(doc, admin_user_uuid)

  def ensure_for_inventory(%InventoryDocument{storage_folder_uuid: uuid} = doc, admin_user_uuid)
      when not is_nil(uuid) do
    ensure_cached(doc, admin_user_uuid, "inventory", &Inventories.set_storage_folder/2)
  end

  def ensure_for_inventory(%InventoryDocument{} = doc, admin_user_uuid) do
    create_and_cache(doc, admin_user_uuid, "inventory", &Inventories.set_storage_folder/2)
  end

  @doc """
  Returns `{:ok, %Folder{}}` for the given supplier order, creating the folder
  if needed. Persists `storage_folder_uuid` on the order record after first
  creation. Pass `admin_user_uuid` as the folder owner.
  """
  def ensure_for_supplier_order(order, admin_user_uuid)

  def ensure_for_supplier_order(
        %SupplierOrder{storage_folder_uuid: uuid} = order,
        admin_user_uuid
      )
      when not is_nil(uuid) do
    ensure_cached(order, admin_user_uuid, "supplier-order", &SupplierOrders.set_storage_folder/2)
  end

  def ensure_for_supplier_order(%SupplierOrder{} = order, admin_user_uuid) do
    create_and_cache(
      order,
      admin_user_uuid,
      "supplier-order",
      &SupplierOrders.set_storage_folder/2
    )
  end

  @doc """
  Returns `{:ok, %Folder{}}` for the given internal order, creating the
  folder if needed. Resolves the folder by name on every call — internal
  orders have no `storage_folder_uuid` column to cache against (dropped
  along with `sub_order_uuid`; nothing in Plan 1's migration created either
  column on `phoenix_kit_warehouse_internal_orders`). Pass `admin_user_uuid`
  as the folder owner.
  """
  def ensure_for_internal_order(%InternalOrder{} = order, admin_user_uuid) do
    name = folder_name("internal-order", order.number, order.uuid)
    find_or_create(name, nil, admin_user_uuid)
  end

  # ---------------------------------------------------------------------------
  # Shared fast-path / create-and-cache helpers (the 4 full-pattern resources)
  # ---------------------------------------------------------------------------

  defp ensure_cached(%{storage_folder_uuid: uuid} = doc, admin_user_uuid, prefix, set_folder_fn) do
    case Storage.get_folder(uuid) do
      nil ->
        # Folder was deleted from /admin/media — clear the dangling link and re-create
        {:ok, _} = set_folder_fn.(doc, nil)

        create_and_cache(
          %{doc | storage_folder_uuid: nil},
          admin_user_uuid,
          prefix,
          set_folder_fn
        )

      folder ->
        {:ok, folder}
    end
  end

  defp create_and_cache(doc, admin_user_uuid, prefix, set_folder_fn) do
    name = folder_name(prefix, doc.number, doc.uuid)

    with {:ok, folder} <- find_or_create(name, nil, admin_user_uuid),
         {:ok, _} <- set_folder_fn.(doc, folder.uuid) do
      {:ok, folder}
    end
  end

  defp find_or_create(name, parent_uuid, user_uuid) do
    case find_by_name(name, parent_uuid) do
      %StorageFolder{} = folder ->
        {:ok, folder}

      nil ->
        case Storage.create_folder(%{name: name, parent_uuid: parent_uuid, user_uuid: user_uuid}) do
          {:ok, folder} ->
            {:ok, folder}

          {:error, %Ecto.Changeset{errors: errors}} ->
            # Unique constraint race — another process created it between our lookup and insert.
            if Keyword.has_key?(errors, :name) do
              {:ok, find_by_name(name, parent_uuid)}
            else
              {:error, :create_folder_failed}
            end
        end
    end
  end

  defp find_by_name(name, parent_uuid) do
    StorageFolder
    |> where([f], f.name == ^name)
    |> where_parent(parent_uuid)
    |> repo().one()
  end

  defp where_parent(query, nil), do: where(query, [f], is_nil(f.parent_uuid))
  defp where_parent(query, uuid), do: where(query, [f], f.parent_uuid == ^uuid)

  defp folder_name(prefix, number, uuid) do
    case number do
      n when (is_binary(n) and n != "") or is_integer(n) -> "#{prefix}-#{n}"
      _ -> "#{prefix}-#{uuid}"
    end
  end
end
