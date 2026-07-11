defmodule PhoenixKitWarehouse.Web.Components.WarehouseHeader do
  @moduledoc """
  Shared tab navigation for the Warehouse section.

  Renders the "In stock" / "Stocktakes" / ... tab bar. Each tab's primary
  "create new" action lives in that tab's own table toolbar (next to the sort
  control), not here. Tab links use `navigate` (not `patch`) since each tab is
  served by a separate LiveView module — `Warehouse.StockLive`, `Warehouse.Index`, etc.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  attr(:active, :atom, required: true)

  def warehouse_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-2 mb-4">
      <div role="tablist" class="tabs tabs-border">
        <.link
          role="tab"
          navigate={PhoenixKit.Utils.Routes.path("/admin/warehouse")}
          class={["tab", @active == :stock && "tab-active"]}
        >
          {dgettext("default", "In stock")}
        </.link>
        <.link
          role="tab"
          navigate={PhoenixKit.Utils.Routes.path("/admin/warehouse/inventories")}
          class={["tab", @active == :inventories && "tab-active"]}
        >
          {dgettext("default", "Stocktakes")}
        </.link>
        <.link
          role="tab"
          navigate={PhoenixKit.Utils.Routes.path("/admin/warehouse/internal-orders")}
          class={["tab", @active == :internal_orders && "tab-active"]}
        >
          {dgettext("default", "Internal Orders")}
        </.link>
        <.link
          role="tab"
          navigate={PhoenixKit.Utils.Routes.path("/admin/warehouse/supplier-orders")}
          class={["tab", @active == :supplier_orders && "tab-active"]}
        >
          {dgettext("default", "Supplier Orders")}
        </.link>
        <.link
          role="tab"
          navigate={PhoenixKit.Utils.Routes.path("/admin/warehouse/transfers")}
          class={["tab", @active == :transfers && "tab-active"]}
        >
          {dgettext("default", "Transfers")}
        </.link>
        <.link
          role="tab"
          navigate={PhoenixKit.Utils.Routes.path("/admin/warehouse/goods-receipts")}
          class={["tab", @active == :goods_receipts && "tab-active"]}
        >
          {dgettext("default", "Goods Receipt")}
        </.link>
        <.link
          role="tab"
          navigate={PhoenixKit.Utils.Routes.path("/admin/warehouse/goods-issues")}
          class={["tab", @active == :goods_issues && "tab-active"]}
        >
          {dgettext("default", "Goods Issue")}
        </.link>
      </div>
    </div>
    """
  end
end
