defmodule PhoenixKitWarehouse.Web.SettingsLive do
  @moduledoc """
  Warehouse-location settings page (`/admin/settings/warehouse`).

  Extracted from the warehouse section of Andi's `/admin/settings/andi`
  page (`lib/andi_web/live/admin/settings/andi.ex`) — which location type
  marks warehouses and which location is the default warehouse for stock.
  Both persist to `PhoenixKit.Settings` (admin-configurable, no redeploy)
  via `PhoenixKitWarehouse.StockLedger`.

  Admin-chrome pattern: `use PhoenixKitWeb, :live_view` + `<.admin_page_header>`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitLocations.Locations

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  @impl true
  def handle_event("set_warehouse_type", %{"value" => raw}, socket) do
    type_uuid = blank_to_nil(raw)
    StockLedger.set_warehouse_location_type_uuid(type_uuid)

    # Clear the default warehouse if it no longer belongs to the chosen type.
    locations = locations_for_type(type_uuid)
    current_default = StockLedger.default_location_uuid()

    if current_default && not Enum.any?(locations, &(&1.uuid == current_default)) do
      StockLedger.set_default_location_uuid(nil)
    end

    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("set_default_location", %{"value" => raw}, socket) do
    StockLedger.set_default_location_uuid(blank_to_nil(raw))
    {:noreply, load(socket)}
  end

  # ---------------------------------------------------------------------------

  defp load(socket) do
    type_uuid = StockLedger.warehouse_location_type_uuid()

    socket
    |> assign(:page_title, dgettext("default", "Warehouse settings"))
    |> assign(:location_types, Locations.list_location_types())
    |> assign(:warehouse_type_uuid, type_uuid)
    |> assign(:locations, locations_for_type(type_uuid))
    |> assign(:default_location_uuid, StockLedger.default_location_uuid())
  end

  defp locations_for_type(nil), do: []
  defp locations_for_type(type_uuid), do: Locations.list_locations(type_uuid: type_uuid)

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={dgettext("default", "Warehouse settings")}
      current_path={
        assigns[:url_path] || assigns[:current_path] ||
          PhoenixKit.Utils.Routes.path("/admin/settings/warehouse")
      }
      current_locale={assigns[:current_locale]}
    >
    <div class="flex flex-col mx-auto max-w-none sm:px-4 py-2 sm:py-6 gap-2">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body p-4 gap-4">
          <p class="text-sm text-base-content/60">
            {dgettext(
              "default",
              "Choose which location type marks warehouses and the default warehouse where stock is held."
            )}
          </p>

          <form phx-change="set_warehouse_type" class="flex flex-col gap-1 max-w-md">
            <label class="text-sm font-medium">
              {dgettext("default", "Warehouse location type")}
            </label>
            <select name="value" class="select select-bordered select-sm">
              <option value="">{dgettext("default", "Not set")}</option>
              <option
                :for={t <- @location_types}
                value={t.uuid}
                selected={t.uuid == @warehouse_type_uuid}
              >
                {t.name}
              </option>
            </select>
          </form>

          <form phx-change="set_default_location" class="flex flex-col gap-1 max-w-md">
            <label class="text-sm font-medium">{dgettext("default", "Default warehouse")}</label>
            <select
              name="value"
              class="select select-bordered select-sm"
              disabled={@warehouse_type_uuid == nil}
            >
              <option value="">{dgettext("default", "Not set")}</option>
              <option
                :for={l <- @locations}
                value={l.uuid}
                selected={l.uuid == @default_location_uuid}
              >
                {l.name}
              </option>
            </select>
            <span :if={@warehouse_type_uuid == nil} class="text-xs text-base-content/50">
              {dgettext("default", "Select a warehouse location type first.")}
            </span>
          </form>
        </div>
      </div>
    </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
