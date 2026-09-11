defmodule PhoenixKitWarehouse.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the exact
  URLs `admin_tabs/0` serves in production (`/admin/andi/warehouse/...`,
  under the default-locale `/en` prefix `PhoenixKit.Utils.Routes.path/1`
  prepends), so `live/2` calls in tests work with exactly the same URLs
  the LiveViews navigate to themselves.

  `on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}]` is the
  same on_mount hook production's `phoenix_kit_admin_routes/1` wires for
  every plugin admin tab (`PhoenixKitWeb.Integration.generate_admin_routes/1`
  — `PhoenixKit.ModuleDiscovery` auto-discovers `PhoenixKitWarehouse` via its
  `use PhoenixKit.Module` beam attribute and folds its `admin_tabs/0`,
  hidden CRUD tabs included, into the SAME `live_session :phoenix_kit_admin`
  as core's own admin views).

  I170: this previously used `:phoenix_kit_mount_current_scope` — the
  PUBLIC surface's on_mount, which only resolves the scope and never denies
  anyone — despite an earlier (incorrect) version of this moduledoc calling
  it "the same real, production on_mount". It was not: production's admin
  surface gates on `:phoenix_kit_ensure_admin`, which redirects a
  confirmed-but-permission-less scope before the LiveView ever mounts. That
  mismatch is why a non-admin got `{:ok, view}` here while every real
  deployment (routed through `PhoenixKitWeb.Integration.phoenix_kit_routes/0`)
  redirects — this router's own on_mount simply never ran the gate, in this
  test app only.
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
      on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}],
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

      live("/transfers", TransferIndexLive, :index)
      live("/transfers/new", TransferFormLive, :new)
      live("/transfers/:uuid", TransferFormLive, :edit)
      live("/transfers/:uuid/items", TransferFormLive, :items)
      live("/transfers/:uuid/files", TransferFormLive, :files)
      live("/transfers/:uuid/comments", TransferFormLive, :comments)

      live("/turnover", TurnoverReportLive, :index)
    end
  end
end
