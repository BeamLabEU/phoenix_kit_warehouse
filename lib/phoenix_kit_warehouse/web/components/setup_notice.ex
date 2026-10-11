defmodule PhoenixKitWarehouse.Web.Components.SetupNotice do
  @moduledoc """
  Warning shown at the top of the Warehouse pages while the module is enabled
  but not configured yet.

  Takes the result of `PhoenixKitWarehouse.StockLedger.setup_status/0`, renders
  nothing for `:ready`, and otherwise explains the current step with buttons
  that lead to the Locations pages and the Warehouse settings page. The
  Locations buttons appear only while the Locations module is available and
  enabled; the settings button is always there.

  LiveViews assign the status once in `mount/3` with `assign_setup_status/1`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWarehouse.StockLedger

  @doc "Assigns `:setup_status` (see `PhoenixKitWarehouse.StockLedger.setup_status/0`)."
  def assign_setup_status(socket) do
    assign(socket, :setup_status, StockLedger.setup_status())
  end

  attr(:status, :any, required: true, doc: "`:ready` or `{:needs, step}`")

  def setup_notice(%{status: :ready} = assigns), do: ~H""

  def setup_notice(%{status: {:needs, step}} = assigns) do
    locations_link = locations_link(step)

    assigns =
      assigns
      |> assign(:step, step)
      |> assign(:locations_link, locations_link)
      |> assign(:settings_class, settings_class(locations_link))

    ~H"""
    <div
      id="warehouse-setup-notice"
      data-step={@step}
      role="status"
      class="alert alert-warning alert-vertical sm:alert-horizontal"
    >
      <.icon name="hero-exclamation-triangle" class="h-6 w-6 shrink-0" />
      <div>
        <p class="font-bold">{dgettext("default", "Warehouse is not set up yet")}</p>
        <div class="text-sm">{step_text(@step)}</div>
      </div>
      <div class="flex flex-wrap gap-2">
        <.link
          :if={@locations_link}
          id="warehouse-setup-locations-link"
          navigate={Routes.path(@locations_link.path)}
          class="btn btn-sm btn-primary"
        >
          {@locations_link.label}
        </.link>
        <.link
          id="warehouse-setup-settings-link"
          navigate={Routes.path("/admin/settings/warehouse")}
          class={["btn btn-sm", @settings_class]}
        >
          {dgettext("default", "Warehouse settings")}
        </.link>
      </div>
    </div>
    """
  end

  defp step_text(:location_type) do
    dgettext(
      "default",
      "Create a location type for warehouses in Locations, then choose it in Warehouse settings."
    )
  end

  defp step_text(:locations) do
    dgettext("default", "Add at least one location of the warehouse type in Locations.")
  end

  defp step_text(:default_location) do
    dgettext("default", "Choose the default warehouse in Warehouse settings.")
  end

  # %{path:, label:} of the Locations button for the step, or nil when the step
  # has none or the Locations module is not available.
  defp locations_link(step) do
    if locations_enabled?(), do: locations_link_for(step)
  end

  defp locations_link_for(:location_type),
    do: %{path: "/admin/locations/types", label: dgettext("default", "Open Locations")}

  defp locations_link_for(:locations),
    do: %{path: "/admin/locations/new", label: dgettext("default", "Add a location")}

  defp locations_link_for(:default_location), do: nil

  defp settings_class(nil), do: "btn-primary"
  defp settings_class(_locations_link), do: "btn-outline"

  defp locations_enabled? do
    Code.ensure_loaded?(PhoenixKitLocations) and PhoenixKitLocations.enabled?()
  end
end
