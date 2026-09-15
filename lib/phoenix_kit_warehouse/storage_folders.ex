defmodule PhoenixKitWarehouse.StorageFolders do
  @moduledoc """
  Resolves (and creates if missing) the PhoenixKit Storage folder for a
  warehouse document.

  Consolidates what were 5 near-identical `*_storage_folders.ex` modules in
  Andi (`goods_issue_storage_folders.ex`, `goods_receipt_storage_folders.ex`,
  `inventory_storage_folders.ex`, `supplier_order_storage_folders.ex`,
  `internal_order_storage_folders.ex`) into one module with 5 `ensure_for_*/2`
  functions.

  Layout: `<prefix>-<number>` (falling back to `<prefix>-<uuid>` when the
  document has no number yet), created under the parent folder returned by
  the optional host hook

      config :phoenix_kit_warehouse, :storage_parent_folder, {MyApp.Media, :for_warehouse}

  called as `for_warehouse(resource, actor_uuid)` with `resource` one of
  `:goods_issue | :goods_receipt | :inventory | :supplier_order |
  :internal_order | :transfer`, returning `{:ok, parent_folder_uuid}` or
  `nil` (= storage root, the default when the hook is absent). A hook that
  raises or returns something other than a UUID is logged and treated as
  `nil`. Lookup by name ignores trashed folders and checks the parent
  first, then the root; a root hit — or a cached folder still sitting at the
  root — is adopted (moved under the parent) so folders created before the
  hook existed keep their files. A failed move leaves the folder at the root.

  Four of the five original resources (goods issue, goods receipt, inventory,
  supplier order) cache the resolved folder's uuid on a `storage_folder_uuid`
  column and take a fast path once cached. The fifth — internal orders — has
  no `storage_folder_uuid` column at all (confirmed: `internal_order_storage_folders.ex`
  is a genuine smaller variant with a single function clause and no
  write-back) and resolves by name on every call instead.

  A sixth resource, transfers (added later, Plan 4/T15), also has a
  `storage_folder_uuid` column and follows the same cached fast-path as the
  four originals — see `ensure_for_transfer/2`.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder, as: StorageFolder
  alias PhoenixKitWarehouse.{GoodsIssue, GoodsIssues}
  alias PhoenixKitWarehouse.{GoodsReceipt, GoodsReceipts}
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.{Inventories, InventoryDocument}
  alias PhoenixKitWarehouse.{SupplierOrder, SupplierOrders}
  alias PhoenixKitWarehouse.{Transfer, Transfers}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Returns `{:ok, %Folder{}}` for the given goods issue, creating the folder
  if needed. Persists `storage_folder_uuid` on the issue record after first
  creation. Pass `admin_user_uuid` as the folder owner.
  """
  def ensure_for_goods_issue(issue, admin_user_uuid)

  def ensure_for_goods_issue(%GoodsIssue{storage_folder_uuid: uuid} = issue, admin_user_uuid)
      when not is_nil(uuid) do
    ensure_cached(
      issue,
      admin_user_uuid,
      :goods_issue,
      "goods-issue",
      &GoodsIssues.set_storage_folder/2
    )
  end

  def ensure_for_goods_issue(%GoodsIssue{} = issue, admin_user_uuid) do
    create_and_cache(
      issue,
      admin_user_uuid,
      :goods_issue,
      "goods-issue",
      &GoodsIssues.set_storage_folder/2
    )
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
    ensure_cached(
      receipt,
      admin_user_uuid,
      :goods_receipt,
      "goods-receipt",
      &GoodsReceipts.set_storage_folder/2
    )
  end

  def ensure_for_goods_receipt(%GoodsReceipt{} = receipt, admin_user_uuid) do
    create_and_cache(
      receipt,
      admin_user_uuid,
      :goods_receipt,
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
    ensure_cached(
      doc,
      admin_user_uuid,
      :inventory,
      "inventory",
      &Inventories.set_storage_folder/2
    )
  end

  def ensure_for_inventory(%InventoryDocument{} = doc, admin_user_uuid) do
    create_and_cache(
      doc,
      admin_user_uuid,
      :inventory,
      "inventory",
      &Inventories.set_storage_folder/2
    )
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
    ensure_cached(
      order,
      admin_user_uuid,
      :supplier_order,
      "supplier-order",
      &SupplierOrders.set_storage_folder/2
    )
  end

  def ensure_for_supplier_order(%SupplierOrder{} = order, admin_user_uuid) do
    create_and_cache(
      order,
      admin_user_uuid,
      :supplier_order,
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
    find_or_create(name, parent_uuid_for(:internal_order, admin_user_uuid), admin_user_uuid)
  end

  @doc """
  Returns `{:ok, %Folder{}}` for the given transfer, creating the folder if
  needed. Persists `storage_folder_uuid` on the transfer record after first
  creation. Pass `admin_user_uuid` as the folder owner.
  """
  def ensure_for_transfer(transfer, admin_user_uuid)

  def ensure_for_transfer(%Transfer{storage_folder_uuid: uuid} = transfer, admin_user_uuid)
      when not is_nil(uuid) do
    ensure_cached(
      transfer,
      admin_user_uuid,
      :transfer,
      "transfer",
      &Transfers.set_storage_folder/2
    )
  end

  def ensure_for_transfer(%Transfer{} = transfer, admin_user_uuid) do
    create_and_cache(
      transfer,
      admin_user_uuid,
      :transfer,
      "transfer",
      &Transfers.set_storage_folder/2
    )
  end

  # ---------------------------------------------------------------------------
  # Shared fast-path / create-and-cache helpers (the 5 full-pattern resources)
  # ---------------------------------------------------------------------------

  defp ensure_cached(
         %{storage_folder_uuid: uuid} = doc,
         admin_user_uuid,
         resource,
         prefix,
         set_folder_fn
       ) do
    case Storage.get_folder(uuid) do
      nil ->
        # Folder was deleted from /admin/media — clear the dangling link and re-create
        {:ok, _} = set_folder_fn.(doc, nil)

        create_and_cache(
          %{doc | storage_folder_uuid: nil},
          admin_user_uuid,
          resource,
          prefix,
          set_folder_fn
        )

      %StorageFolder{parent_uuid: nil} = folder ->
        # Cached before the host configured a parent — move it under the parent now.
        {:ok, adopt(folder, parent_uuid_for(resource, admin_user_uuid))}

      folder ->
        {:ok, folder}
    end
  end

  defp create_and_cache(doc, admin_user_uuid, resource, prefix, set_folder_fn) do
    name = folder_name(prefix, doc.number, doc.uuid)
    parent_uuid = parent_uuid_for(resource, admin_user_uuid)

    with {:ok, folder} <- find_or_create(name, parent_uuid, admin_user_uuid),
         {:ok, _} <- set_folder_fn.(doc, folder.uuid) do
      {:ok, folder}
    end
  end

  @doc false
  # Host-configured parent folder for a resource kind; nil = storage root.
  def parent_uuid_for(resource, actor_uuid) do
    case Application.get_env(:phoenix_kit_warehouse, :storage_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        call_parent_hook(mod, fun, resource, actor_uuid)

      _ ->
        nil
    end
  end

  # Host code: a raising hook or a non-UUID return must not crash the folder
  # task (the form would spin forever) — fall back to the root, which a later
  # call adopts once the hook is fixed.
  defp call_parent_hook(mod, fun, resource, actor_uuid) do
    case apply(mod, fun, [resource, actor_uuid]) do
      result when result in [nil, {:ok, nil}] ->
        nil

      {:ok, uuid} = result when is_binary(uuid) ->
        case Ecto.UUID.cast(uuid) do
          {:ok, uuid} -> uuid
          :error -> hook_failed(mod, fun, "returned #{inspect(result)}")
        end

      other ->
        hook_failed(mod, fun, "returned #{inspect(other)}")
    end
  rescue
    e -> hook_failed(mod, fun, "raised #{Exception.message(e)}")
  catch
    :exit, reason -> hook_failed(mod, fun, "exited #{inspect(reason)}")
  end

  defp hook_failed(mod, fun, what) do
    Logger.warning(
      "[PhoenixKitWarehouse] storage_parent_folder hook #{inspect(mod)}.#{fun}/2 #{what}; " <>
        "using storage root"
    )

    nil
  end

  defp find_or_create(name, parent_uuid, user_uuid) do
    case find_by_name(name, parent_uuid) || adopt_from_root(name, parent_uuid) do
      %StorageFolder{} = folder -> {:ok, folder}
      nil -> create_folder(name, parent_uuid, user_uuid)
    end
  end

  defp create_folder(name, parent_uuid, user_uuid) do
    case Storage.create_folder(%{name: name, parent_uuid: parent_uuid, user_uuid: user_uuid}) do
      {:ok, folder} ->
        {:ok, folder}

      {:error, %Ecto.Changeset{errors: errors}} ->
        # Unique constraint race — another process created it between our lookup and insert.
        with true <- Keyword.has_key?(errors, :name),
             %StorageFolder{} = folder <- find_by_name(name, parent_uuid) do
          {:ok, folder}
        else
          _ -> {:error, :create_folder_failed}
        end
    end
  end

  defp adopt_from_root(_name, nil), do: nil

  defp adopt_from_root(name, parent_uuid) do
    case find_by_name(name, nil) do
      %StorageFolder{} = legacy -> adopt(legacy, parent_uuid)
      nil -> nil
    end
  end

  defp adopt(folder, nil), do: folder

  defp adopt(folder, parent_uuid) do
    case Storage.update_folder(folder, %{parent_uuid: parent_uuid}) do
      {:ok, moved} -> moved
      {:error, _} -> folder
    end
  end

  # Trashed folders are outside the (name, parent) unique index, so a live and
  # a trashed folder can share a name — match live ones only, or `one/1` raises.
  defp find_by_name(name, parent_uuid) do
    StorageFolder
    |> where([f], f.name == ^name and is_nil(f.trashed_at))
    |> where_parent(parent_uuid)
    |> repo().one()
  end

  defp where_parent(query, nil), do: where(query, [f], is_nil(f.parent_uuid))
  defp where_parent(query, uuid), do: where(query, [f], f.parent_uuid == ^uuid)

  @doc false
  # Exposed (not just private) so `PhoenixKitWarehouse.MediaReorganizer` can
  # compute the same deterministic legacy name instead of duplicating this
  # formatting rule.
  def folder_name(prefix, number, uuid) do
    case number do
      n when (is_binary(n) and n != "") or is_integer(n) -> "#{prefix}-#{n}"
      _ -> "#{prefix}-#{uuid}"
    end
  end
end
