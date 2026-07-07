defmodule PhoenixKitWarehouse do
  @moduledoc """
  PhoenixKit module: stock, stocktakes, internal orders, supplier orders,
  goods receipt, and goods issue.

  Hard-depends on `phoenix_kit_catalogue` (warehouse only ever tracks
  catalogue items) and `phoenix_kit_locations` (every document carries a
  `location_uuid` resolved through it) — see `required_modules/0`.

  `PhoenixKitComments` stays optional (guarded via `Code.ensure_loaded?/1`
  in the document context modules — see Plan 3).

  Documents link to host-owned records (a sub-order, a top-level order, or
  anything else a consuming app wants to link) through the generic
  `PhoenixKitWarehouse.SourceKinds` registry rather than a direct dependency
  on any specific "order" concept — see that module's docs.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKitWarehouse.Web.GoodsIssueFormLive
  alias PhoenixKitWarehouse.Web.GoodsIssueIndexLive
  alias PhoenixKitWarehouse.Web.GoodsReceiptFormLive
  alias PhoenixKitWarehouse.Web.GoodsReceiptIndexLive
  alias PhoenixKitWarehouse.Web.InventoriesLive
  alias PhoenixKitWarehouse.Web.InventoryFormLive
  alias PhoenixKitWarehouse.Web.InternalOrderFormLive
  alias PhoenixKitWarehouse.Web.InternalOrderIndexLive
  alias PhoenixKitWarehouse.Web.StockLive
  alias PhoenixKitWarehouse.Web.SupplierOrderFormLive
  alias PhoenixKitWarehouse.Web.SupplierOrderIndexLive

  @version Mix.Project.config()[:version]

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def module_key, do: "warehouse"

  @impl PhoenixKit.Module
  def module_name, do: "Warehouse"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("warehouse_enabled", false)
  rescue
    _ -> false
  catch
    # Sandbox-owner-exited race: a non-DataCase test calls `enabled?/0`
    # right as a sibling test's owner pid has stopped. The pool checkout
    # exits before we even reach the `rescue` clause, so we have to
    # `catch :exit` separately. Returning `false` is correct — if we
    # can't read the setting, the module is effectively disabled.
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    result =
      Settings.update_boolean_setting_with_module("warehouse_enabled", true, module_key())

    PhoenixKit.Activity.log(%{
      action: "warehouse_module.enabled",
      mode: "manual",
      resource_type: "module",
      metadata: %{"module_key" => module_key()}
    })

    result
  end

  @impl PhoenixKit.Module
  def disable_system do
    result =
      Settings.update_boolean_setting_with_module("warehouse_enabled", false, module_key())

    PhoenixKit.Activity.log(%{
      action: "warehouse_module.disabled",
      mode: "manual",
      resource_type: "module",
      metadata: %{"module_key" => module_key()}
    })

    result
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  def required_modules, do: ["catalogue", "locations"]

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_warehouse]

  @impl PhoenixKit.Module
  def children, do: [{Task.Supervisor, name: PhoenixKitWarehouse.TaskSupervisor}]

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      # --- Root: "In stock" — hosts StockLive directly, not a redirect stub.
      %Tab{
        id: :warehouse,
        label: "Warehouse",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-building-storefront",
        path: "andi/warehouse",
        match: :exact,
        priority: 153,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        live_view: {StockLive, :index}
      },
      %Tab{
        id: :warehouse_inventories,
        label: "Stocktakes",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-clipboard-document-check",
        path: "andi/warehouse/inventories",
        parent: :warehouse,
        priority: 155,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        live_view: {InventoriesLive, :inventories}
      },
      %Tab{
        id: :warehouse_internal_orders,
        label: "Internal Orders",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-document-text",
        path: "andi/warehouse/internal-orders",
        parent: :warehouse,
        priority: 156,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        live_view: {InternalOrderIndexLive, :index}
      },
      %Tab{
        id: :warehouse_supplier_orders,
        label: "Supplier Orders",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-truck",
        path: "andi/warehouse/supplier-orders",
        parent: :warehouse,
        priority: 157,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        live_view: {SupplierOrderIndexLive, :index}
      },
      %Tab{
        id: :warehouse_goods_receipts,
        label: "Goods Receipt",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-arrow-down-tray",
        path: "andi/warehouse/goods-receipts",
        parent: :warehouse,
        priority: 158,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        live_view: {GoodsReceiptIndexLive, :index}
      },
      %Tab{
        id: :warehouse_goods_issues,
        label: "Goods Issue",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-arrow-up-tray",
        path: "andi/warehouse/goods-issues",
        parent: :warehouse,
        priority: 159,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        live_view: {GoodsIssueIndexLive, :index}
      }
    ] ++ hidden_crud_tabs()
  end

  # Hidden CRUD-form tabs — never shown in the sidebar (visible: false), but
  # registered so their routes exist and so PhoenixKit's tab-permission gate
  # covers them. Priorities match today's config.exs exactly.
  defp hidden_crud_tabs do
    [
      %Tab{
        id: :warehouse_inventory_new,
        label: "New Inventory",
        path: "andi/warehouse/inventory/new",
        parent: :warehouse,
        priority: 562,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {InventoryFormLive, :new}
      },
      %Tab{
        id: :warehouse_inventory_edit,
        label: "Edit Inventory",
        path: "andi/warehouse/inventory/:uuid",
        parent: :warehouse,
        priority: 563,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {InventoryFormLive, :edit}
      },
      %Tab{
        id: :warehouse_inventory_items,
        label: "Inventory Items",
        path: "andi/warehouse/inventory/:uuid/items",
        parent: :warehouse,
        priority: 564,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {InventoryFormLive, :items}
      },
      %Tab{
        id: :warehouse_inventory_files,
        label: "Inventory Files",
        path: "andi/warehouse/inventory/:uuid/files",
        parent: :warehouse,
        priority: 565,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {InventoryFormLive, :files}
      },
      %Tab{
        id: :warehouse_inventory_comments,
        label: "Inventory Comments",
        path: "andi/warehouse/inventory/:uuid/comments",
        parent: :warehouse,
        priority: 566,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {InventoryFormLive, :comments}
      },
      %Tab{
        id: :warehouse_internal_order_new,
        label: "New Internal Order",
        path: "andi/warehouse/internal-orders/new",
        parent: :warehouse,
        priority: 570,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {InternalOrderFormLive, :new}
      },
      %Tab{
        id: :warehouse_internal_order_edit,
        label: "Edit Internal Order",
        path: "andi/warehouse/internal-orders/:uuid",
        parent: :warehouse,
        priority: 571,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {InternalOrderFormLive, :edit}
      },
      %Tab{
        id: :warehouse_internal_order_items,
        label: "Internal Order Items",
        path: "andi/warehouse/internal-orders/:uuid/items",
        parent: :warehouse,
        priority: 572,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {InternalOrderFormLive, :items}
      },
      %Tab{
        id: :warehouse_internal_order_files,
        label: "Internal Order Files",
        path: "andi/warehouse/internal-orders/:uuid/files",
        parent: :warehouse,
        priority: 573,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {InternalOrderFormLive, :files}
      },
      %Tab{
        id: :warehouse_internal_order_comments,
        label: "Internal Order Comments",
        path: "andi/warehouse/internal-orders/:uuid/comments",
        parent: :warehouse,
        priority: 574,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {InternalOrderFormLive, :comments}
      },
      %Tab{
        id: :warehouse_supplier_order_new,
        label: "New Supplier Order",
        path: "andi/warehouse/supplier-orders/new",
        parent: :warehouse,
        priority: 580,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {SupplierOrderFormLive, :new}
      },
      %Tab{
        id: :warehouse_supplier_order_edit,
        label: "Edit Supplier Order",
        path: "andi/warehouse/supplier-orders/:uuid",
        parent: :warehouse,
        priority: 581,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {SupplierOrderFormLive, :edit}
      },
      %Tab{
        id: :warehouse_supplier_order_lines,
        label: "Supplier Order Lines",
        path: "andi/warehouse/supplier-orders/:uuid/lines",
        parent: :warehouse,
        priority: 582,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {SupplierOrderFormLive, :lines}
      },
      %Tab{
        id: :warehouse_supplier_order_files,
        label: "Supplier Order Files",
        path: "andi/warehouse/supplier-orders/:uuid/files",
        parent: :warehouse,
        priority: 583,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {SupplierOrderFormLive, :files}
      },
      %Tab{
        id: :warehouse_supplier_order_comments,
        label: "Supplier Order Comments",
        path: "andi/warehouse/supplier-orders/:uuid/comments",
        parent: :warehouse,
        priority: 584,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {SupplierOrderFormLive, :comments}
      },
      %Tab{
        id: :warehouse_goods_receipt_new,
        label: "New Goods Receipt",
        path: "andi/warehouse/goods-receipts/new",
        parent: :warehouse,
        priority: 591,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {GoodsReceiptFormLive, :new}
      },
      %Tab{
        id: :warehouse_goods_receipt_edit,
        label: "Goods Receipt",
        path: "andi/warehouse/goods-receipts/:uuid",
        parent: :warehouse,
        priority: 592,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {GoodsReceiptFormLive, :edit}
      },
      %Tab{
        id: :warehouse_goods_receipt_lines,
        label: "Goods Receipt Lines",
        path: "andi/warehouse/goods-receipts/:uuid/lines",
        parent: :warehouse,
        priority: 593,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {GoodsReceiptFormLive, :lines}
      },
      %Tab{
        id: :warehouse_goods_receipt_files,
        label: "Goods Receipt Files",
        path: "andi/warehouse/goods-receipts/:uuid/files",
        parent: :warehouse,
        priority: 594,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {GoodsReceiptFormLive, :files}
      },
      %Tab{
        id: :warehouse_goods_receipt_comments,
        label: "Goods Receipt Comments",
        path: "andi/warehouse/goods-receipts/:uuid/comments",
        parent: :warehouse,
        priority: 595,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {GoodsReceiptFormLive, :comments}
      },
      %Tab{
        id: :warehouse_goods_issue_new,
        label: "New Goods Issue",
        path: "andi/warehouse/goods-issues/new",
        parent: :warehouse,
        priority: 601,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {GoodsIssueFormLive, :new}
      },
      %Tab{
        id: :warehouse_goods_issue_edit,
        label: "Goods Issue",
        path: "andi/warehouse/goods-issues/:uuid",
        parent: :warehouse,
        priority: 602,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {GoodsIssueFormLive, :edit}
      },
      %Tab{
        id: :warehouse_goods_issue_lines,
        label: "Goods Issue Lines",
        path: "andi/warehouse/goods-issues/:uuid/lines",
        parent: :warehouse,
        priority: 603,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {GoodsIssueFormLive, :lines}
      },
      %Tab{
        id: :warehouse_goods_issue_files,
        label: "Goods Issue Files",
        path: "andi/warehouse/goods-issues/:uuid/files",
        parent: :warehouse,
        priority: 604,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {GoodsIssueFormLive, :files}
      },
      %Tab{
        id: :warehouse_goods_issue_comments,
        label: "Goods Issue Comments",
        path: "andi/warehouse/goods-issues/:uuid/comments",
        parent: :warehouse,
        priority: 605,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {GoodsIssueFormLive, :comments}
      }
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs, do: []
end
