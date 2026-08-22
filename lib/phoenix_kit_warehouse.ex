defmodule PhoenixKitWarehouse do
  @moduledoc """
  PhoenixKit module: multi-warehouse stock scope, stocktakes, transfers with
  cancel reverse-posting, deficit control with min-stock settings, turnover
  report, internal orders, supplier orders, goods receipts, and goods issues.

  All four sibling packages are hard dependencies in `mix.exs` — none is
  declared `optional:`, so all four are always compiled in:

    * `phoenix_kit_catalogue` — warehouse only ever tracks catalogue items.
    * `phoenix_kit_locations` — every document carries a `location_uuid`
      resolved through it.
    * `phoenix_kit_billing` — currency formatting for unit values, via a
      compile-time `import` of `CurrencyDisplay.currency_compact/1`.
    * `phoenix_kit_comments` — six form LiveViews `use
      PhoenixKitComments.Embed`. A `use` is macro expansion at compile time,
      so this one can be neither guarded nor made optional; that is why
      `mix.exs` floors it at 0.2.8 rather than 0.2.

  A hard *package* dependency is not the same thing as a required *module*.
  `required_modules/0` lists only `"catalogue"` and `"locations"` — the two
  whose PhoenixKit modules a host must actually have enabled. Billing is
  never enablement-checked at all (its component is imported, not called
  conditionally), and comments is checked at runtime but not required:
  `PhoenixKitWarehouse.Comments.available?/0` gates every comments call on
  `PhoenixKitComments.enabled?/0`, and all six form LiveViews assign
  `comments_available?` from it, so a host that has the comments module
  installed but switched off simply renders no threads.

  Documents link to host-owned records (a sub-order, a top-level order, or
  anything else a consuming app wants to link) through the generic
  `PhoenixKitWarehouse.SourceKinds` registry rather than a direct dependency
  on any specific "order" concept — see that module's docs.
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKitWarehouse.Web.GoodsIssueFormLive
  alias PhoenixKitWarehouse.Web.GoodsIssueIndexLive
  alias PhoenixKitWarehouse.Web.GoodsReceiptFormLive
  alias PhoenixKitWarehouse.Web.GoodsReceiptIndexLive
  alias PhoenixKitWarehouse.Web.InternalOrderFormLive
  alias PhoenixKitWarehouse.Web.InternalOrderIndexLive
  alias PhoenixKitWarehouse.Web.InventoriesLive
  alias PhoenixKitWarehouse.Web.InventoryFormLive
  alias PhoenixKitWarehouse.Web.SettingsLive
  alias PhoenixKitWarehouse.Web.StockLive
  alias PhoenixKitWarehouse.Web.SupplierOrderFormLive
  alias PhoenixKitWarehouse.Web.SupplierOrderIndexLive
  alias PhoenixKitWarehouse.Web.TransferFormLive
  alias PhoenixKitWarehouse.Web.TransferIndexLive
  alias PhoenixKitWarehouse.Web.TurnoverReportLive

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
  def permission_metadata do
    %{
      key: module_key(),
      label: "Warehouse",
      icon: "hero-building-storefront",
      description: "Warehouse stock, stocktakes, and document management",
      # The strings above and in `admin_tabs/0` are plain data — `mix
      # gettext.extract` never sees this file, so their msgids only reach the
      # catalogue if something else happens to use the same English. See
      # `translatable_labels/0` at the bottom of this module, which pins them.
      # Lets the admin permissions matrix render this label translated,
      # the same way the sidebar tabs below translate theirs.
      gettext_backend: PhoenixKitWarehouse.Gettext,
      gettext_domain: "default"
    }
  end

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
        path: "warehouse",
        match: :exact,
        priority: 153,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        visible: true,
        live_view: {StockLive, :index}
      },
      %Tab{
        id: :warehouse_inventories,
        label: "Stocktakes",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-clipboard-document-check",
        path: "warehouse/inventories",
        parent: :warehouse,
        priority: 155,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        visible: true,
        live_view: {InventoriesLive, :inventories}
      },
      %Tab{
        id: :warehouse_internal_orders,
        label: "Internal Orders",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-document-text",
        path: "warehouse/internal-orders",
        parent: :warehouse,
        priority: 156,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        visible: true,
        live_view: {InternalOrderIndexLive, :index}
      },
      %Tab{
        id: :warehouse_supplier_orders,
        label: "Supplier Orders",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-truck",
        path: "warehouse/supplier-orders",
        parent: :warehouse,
        priority: 157,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        visible: true,
        live_view: {SupplierOrderIndexLive, :index}
      },
      %Tab{
        id: :warehouse_goods_receipts,
        label: "Goods Receipt",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-arrow-down-tray",
        path: "warehouse/goods-receipts",
        parent: :warehouse,
        priority: 158,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        visible: true,
        live_view: {GoodsReceiptIndexLive, :index}
      },
      %Tab{
        id: :warehouse_goods_issues,
        label: "Goods Issue",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-arrow-up-tray",
        path: "warehouse/goods-issues",
        parent: :warehouse,
        priority: 159,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        visible: true,
        live_view: {GoodsIssueIndexLive, :index}
      },
      %Tab{
        id: :warehouse_transfers,
        label: "Transfers",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-arrows-right-left",
        path: "warehouse/transfers",
        parent: :warehouse,
        priority: 160,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        visible: true,
        live_view: {TransferIndexLive, :index}
      },
      %Tab{
        id: :warehouse_turnover,
        label: "Turnover",
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default",
        icon: "hero-chart-bar",
        path: "warehouse/turnover",
        parent: :warehouse,
        priority: 161,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        visible: true,
        live_view: {TurnoverReportLive, :index}
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
        path: "warehouse/inventory/new",
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
        path: "warehouse/inventory/:uuid",
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
        path: "warehouse/inventory/:uuid/items",
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
        path: "warehouse/inventory/:uuid/files",
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
        path: "warehouse/inventory/:uuid/comments",
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
        path: "warehouse/internal-orders/new",
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
        path: "warehouse/internal-orders/:uuid",
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
        path: "warehouse/internal-orders/:uuid/items",
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
        path: "warehouse/internal-orders/:uuid/files",
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
        path: "warehouse/internal-orders/:uuid/comments",
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
        path: "warehouse/supplier-orders/new",
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
        path: "warehouse/supplier-orders/:uuid",
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
        path: "warehouse/supplier-orders/:uuid/lines",
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
        path: "warehouse/supplier-orders/:uuid/files",
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
        path: "warehouse/supplier-orders/:uuid/comments",
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
        path: "warehouse/goods-receipts/new",
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
        path: "warehouse/goods-receipts/:uuid",
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
        path: "warehouse/goods-receipts/:uuid/lines",
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
        path: "warehouse/goods-receipts/:uuid/files",
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
        path: "warehouse/goods-receipts/:uuid/comments",
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
        path: "warehouse/goods-issues/new",
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
        path: "warehouse/goods-issues/:uuid",
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
        path: "warehouse/goods-issues/:uuid/lines",
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
        path: "warehouse/goods-issues/:uuid/files",
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
        path: "warehouse/goods-issues/:uuid/comments",
        parent: :warehouse,
        priority: 605,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {GoodsIssueFormLive, :comments}
      },
      %Tab{
        id: :warehouse_transfer_new,
        label: "New Transfer",
        path: "warehouse/transfers/new",
        parent: :warehouse,
        priority: 611,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {TransferFormLive, :new}
      },
      %Tab{
        id: :warehouse_transfer_edit,
        label: "Edit Transfer",
        path: "warehouse/transfers/:uuid",
        parent: :warehouse,
        priority: 612,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {TransferFormLive, :edit}
      },
      %Tab{
        id: :warehouse_transfer_items,
        label: "Transfer Items",
        path: "warehouse/transfers/:uuid/items",
        parent: :warehouse,
        priority: 613,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {TransferFormLive, :items}
      },
      %Tab{
        id: :warehouse_transfer_files,
        label: "Transfer Files",
        path: "warehouse/transfers/:uuid/files",
        parent: :warehouse,
        priority: 614,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {TransferFormLive, :files}
      },
      %Tab{
        id: :warehouse_transfer_comments,
        label: "Transfer Comments",
        path: "warehouse/transfers/:uuid/comments",
        parent: :warehouse,
        priority: 615,
        level: :admin,
        permission: module_key(),
        visible: false,
        live_view: {TransferFormLive, :comments}
      }
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      %Tab{
        id: :warehouse_settings,
        label: "Warehouse",
        icon: "hero-building-storefront",
        path: "warehouse",
        priority: 920,
        level: :admin,
        parent: :admin_settings,
        permission: module_key(),
        match: :exact,
        live_view: {SettingsLive, :index},
        gettext_backend: PhoenixKitWarehouse.Gettext,
        gettext_domain: "default"
      }
    ]
  end

  @doc """
  Pins every label this module declares as a gettext msgid.

  `permission_metadata/0`, `admin_tabs/0`, `hidden_crud_tabs/0` and
  `settings_tabs/0` declare their labels as plain string literals, so
  `mix gettext.extract` never sees this file. PhoenixKit translates them at
  render time through each declaration's `gettext_backend`/`gettext_domain` —
  but only if the msgid exists in this module's own catalogue.

  Until this function existed, the tab labels were in `default.pot` purely by
  coincidence: `Web.WarehouseHeader` and `Web.TurnoverReportLive` happen to use
  the same English strings, and their `gettext` macro calls are what the
  extractor found. Rewording either file would have silently reverted eight
  admin tabs to English with no compile error and no failing test.

  `dgettext_noop/2` registers the msgid and returns it unchanged — nothing here
  runs at request time.
  """
  @spec translatable_labels() :: [String.t()]
  def translatable_labels do
    [
      dgettext_noop("default", "Warehouse"),
      dgettext_noop("default", "Warehouse stock, stocktakes, and document management"),
      dgettext_noop("default", "Stocktakes"),
      dgettext_noop("default", "Internal Orders"),
      dgettext_noop("default", "Supplier Orders"),
      dgettext_noop("default", "Goods Receipt"),
      dgettext_noop("default", "Goods Issue"),
      dgettext_noop("default", "Transfers"),
      dgettext_noop("default", "Turnover")
    ]
  end
end
