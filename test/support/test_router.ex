defmodule PhoenixKitWarehouse.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the exact
  URLs `admin_tabs/0` serves in production (`/admin/andi/warehouse/...`,
  under the default-locale `/en` prefix `PhoenixKit.Utils.Routes.path/1`
  prepends), so `live/2` calls in tests work with exactly the same URLs
  the LiveViews navigate to themselves.

  `on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}]`
  is the same real, production on_mount every `phoenix_kit_routes()`
  pipeline wires — it resolves `phoenix_kit_current_scope` from the
  `:user_token` session key, so tests can use PhoenixKit's real
  register/confirm/promote/login helpers unmodified (see Task 14).
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitWarehouse.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/warehouse", PhoenixKitWarehouse.Web do
    pipe_through(:browser)

    live_session :warehouse_test,
      on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}],
      layout: {PhoenixKitWarehouse.Test.Layouts, :app} do
      live("/", StockLive, :index)
      live("/inventories", InventoriesLive, :inventories)
      live("/inventory/new", InventoryFormLive, :new)
      live("/inventory/:uuid", InventoryFormLive, :edit)
      live("/inventory/:uuid/items", InventoryFormLive, :items)
      live("/inventory/:uuid/files", InventoryFormLive, :files)
      live("/inventory/:uuid/comments", InventoryFormLive, :comments)

      live("/internal-orders", InternalOrderIndexLive, :index)
      live("/internal-orders/new", InternalOrderFormLive, :new)
      live("/internal-orders/:uuid", InternalOrderFormLive, :edit)
      live("/internal-orders/:uuid/items", InternalOrderFormLive, :items)
      live("/internal-orders/:uuid/files", InternalOrderFormLive, :files)
      live("/internal-orders/:uuid/comments", InternalOrderFormLive, :comments)

      live("/supplier-orders", SupplierOrderIndexLive, :index)
      live("/supplier-orders/new", SupplierOrderFormLive, :new)
      live("/supplier-orders/:uuid", SupplierOrderFormLive, :edit)
      live("/supplier-orders/:uuid/lines", SupplierOrderFormLive, :lines)
      live("/supplier-orders/:uuid/files", SupplierOrderFormLive, :files)
      live("/supplier-orders/:uuid/comments", SupplierOrderFormLive, :comments)

      live("/goods-receipts", GoodsReceiptIndexLive, :index)
      live("/goods-receipts/new", GoodsReceiptFormLive, :new)
      live("/goods-receipts/:uuid", GoodsReceiptFormLive, :edit)
      live("/goods-receipts/:uuid/lines", GoodsReceiptFormLive, :lines)
      live("/goods-receipts/:uuid/files", GoodsReceiptFormLive, :files)
      live("/goods-receipts/:uuid/comments", GoodsReceiptFormLive, :comments)

      live("/goods-issues", GoodsIssueIndexLive, :index)
      live("/goods-issues/new", GoodsIssueFormLive, :new)
      live("/goods-issues/:uuid", GoodsIssueFormLive, :edit)
      live("/goods-issues/:uuid/lines", GoodsIssueFormLive, :lines)
      live("/goods-issues/:uuid/files", GoodsIssueFormLive, :files)
      live("/goods-issues/:uuid/comments", GoodsIssueFormLive, :comments)
    end
  end
end
