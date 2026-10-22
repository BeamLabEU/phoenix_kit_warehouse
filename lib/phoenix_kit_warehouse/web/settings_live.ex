defmodule PhoenixKitWarehouse.Web.SettingsLive do
  @moduledoc """
  Warehouse-location settings page (`/admin/settings/warehouse`).

  Extracted from the warehouse section of Andi's `/admin/settings/andi`
  page (`lib/andi_web/live/admin/settings/andi.ex`) — which location type
  marks warehouses and which location is the default warehouse for stock.
  Both persist to `PhoenixKit.Settings` (admin-configurable, no redeploy)
  via `PhoenixKitWarehouse.StockLedger`.

  A second block, "AI: inventory from photos" (the endpoint, the limits of a
  batch, a link to the prompt), is shown to a holder of the `ai` module or an
  administrator only - checked in `render/1` and again in the event handler -
  and persists through `PhoenixKitWarehouse.InventoryAI.Settings`.

  Admin header-breadcrumb pattern: `use PhoenixKitWeb, :live_view` + a
  `self_wrapped_layout` on_mount wrapping render/1 in `<LayoutWrapper.app_layout>`
  (title in the global admin header).
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Utils.Number
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.InventoryAI.Guard
  alias PhoenixKitWarehouse.InventoryAI.Settings, as: InventoryAISettings
  alias PhoenixKitWarehouse.StockLedger

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

  # The photo inventory block. The endpoint is a choice of where money goes,
  # so the check is made here as well as in `render/1`: an event sent to a
  # page that does not show the block is refused.
  @impl true
  def handle_event("save_inventory_ai", payload, socket) do
    if inventory_ai_access?(socket) do
      {:noreply, save_inventory_ai(socket, payload)}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         dgettext("default", "Only a holder of the AI module can change these settings.")
       )}
    end
  end

  # ---------------------------------------------------------------------------

  # A holder of the `ai` module or an administrator (Admin or Owner role) -
  # not `can_access_admin_area?/1`, which any holder of a single permission,
  # the warehouse's own included, passes.
  defp inventory_ai_access?(%{assigns: assigns}) do
    case assigns[:phoenix_kit_current_scope] do
      nil -> false
      scope -> inventory_ai_access_for?(scope)
    end
  end

  defp inventory_ai_access_for?(scope) do
    Scope.has_module_access?(scope, "ai") or Scope.owner?(scope) or
      Scope.has_role?(scope, Role.system_roles().admin)
  end

  # The answer of the last save is told once: both marks are cleared first, so
  # that a failure never stands next to the "Saved." of the save before it.
  defp save_inventory_ai(socket, %{"inventory_ai" => params}) when is_map(params) do
    socket = assign(socket, inventory_ai_error: nil, inventory_ai_saved?: false)
    options = endpoint_choices(InventoryAISettings.endpoint_uuid())

    with {:ok, endpoint_uuid} <- parse_endpoint(params["endpoint_uuid"], options),
         {:ok, max_photos} <-
           parse_whole(params["max_photos"], InventoryAISettings.max_photos_limit()),
         {:ok, max_items} <-
           parse_whole(params["max_items"], InventoryAISettings.max_items_limit()),
         :ok <- InventoryAISettings.set_endpoint_uuid(endpoint_uuid),
         :ok <- InventoryAISettings.set_max_photos(max_photos),
         :ok <- InventoryAISettings.set_max_items(max_items) do
      socket |> load_inventory_ai() |> assign(:inventory_ai_saved?, true)
    else
      {:error, :endpoint} ->
        inventory_ai_failed(
          socket,
          dgettext("default", "Choose one of the listed endpoints, or none.")
        )

      {:error, {:number, limit}} ->
        inventory_ai_failed(
          socket,
          dgettext("default", "Enter whole numbers from 1 up to %{limit}.", limit: limit)
        )

      {:error, _reason} ->
        inventory_ai_failed(socket, dgettext("default", "The settings could not be saved."))
    end
  end

  defp save_inventory_ai(socket, _payload) do
    inventory_ai_failed(
      assign(socket, :inventory_ai_saved?, false),
      dgettext("default", "The settings could not be saved.")
    )
  end

  defp inventory_ai_failed(socket, message), do: assign(socket, :inventory_ai_error, message)

  # Empty clears; otherwise one of the offered endpoints, or the one saved
  # already (it may have been switched off since: saving the page must not
  # drop it behind the person's back).
  defp parse_endpoint(raw, _options) when raw in [nil, ""], do: {:ok, nil}

  defp parse_endpoint(raw, options) when is_binary(raw) do
    if raw in Enum.map(options, & &1.uuid), do: {:ok, raw}, else: {:error, :endpoint}
  end

  defp parse_endpoint(_raw, _options), do: {:error, :endpoint}

  defp parse_whole(raw, limit) do
    with {:ok, decimal} <- Number.parse_decimal(raw, min: 1, max: limit),
         true <- Decimal.integer?(decimal) do
      {:ok, Decimal.to_integer(decimal)}
    else
      _ -> {:error, {:number, limit}}
    end
  end

  defp load_inventory_ai(socket) do
    if inventory_ai_access?(socket) do
      saved = InventoryAISettings.endpoint_uuid()

      socket
      |> assign(:inventory_ai_visible?, true)
      |> assign(:inventory_ai_options, endpoint_choices(saved))
      |> assign(:inventory_ai_endpoint_uuid, saved)
      |> assign(:inventory_ai_max_photos, InventoryAISettings.max_photos())
      |> assign(:inventory_ai_max_items, InventoryAISettings.max_items())
      |> assign(:inventory_ai_prompt_path, prompt_path())
      |> assign(:inventory_ai_error, nil)
      |> assign(:inventory_ai_saved?, false)
    else
      socket
      |> assign(:inventory_ai_visible?, false)
      |> assign(:inventory_ai_options, [])
    end
  end

  # The offered endpoints, and the saved one if it is not among them (switched
  # off or deleted since): it stays a choice, named when it still exists.
  defp endpoint_choices(saved) do
    offered = Guard.endpoint_options()

    if saved && not Enum.any?(offered, &(&1.uuid == saved)),
      do: offered ++ [saved_choice(saved)],
      else: offered
  end

  defp saved_choice(uuid) do
    case PhoenixKitAI.get_endpoint(uuid) do
      nil -> %{uuid: uuid, name: nil, model: nil, offered?: false}
      endpoint -> %{uuid: uuid, name: endpoint.name, model: endpoint.model, offered?: false}
    end
  end

  defp prompt_path do
    uuid = InventoryAISettings.prompt_uuid()

    if uuid && PhoenixKitAI.get_prompt(uuid),
      do: "/admin/ai/prompts/#{uuid}/edit",
      else: "/admin/ai/prompts"
  end

  defp endpoint_label(%{name: nil}), do: dgettext("default", "Unavailable endpoint")

  defp endpoint_label(%{name: name, model: model, offered?: false}),
    do: "#{name} (#{model}) - #{dgettext("default", "no longer offered")}"

  defp endpoint_label(%{name: name, model: model}), do: "#{name} (#{model})"

  defp load(socket) do
    type_uuid = StockLedger.warehouse_location_type_uuid()

    socket
    |> assign(:page_title, dgettext("default", "Warehouse settings"))
    |> assign(:location_types, Locations.list_location_types())
    |> assign(:warehouse_type_uuid, type_uuid)
    |> assign(:locations, locations_for_type(type_uuid))
    |> assign(:default_location_uuid, StockLedger.default_location_uuid())
    |> load_inventory_ai()
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
            <select name="value" class="select select-sm">
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
              class="select select-sm"
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

      <div :if={@inventory_ai_visible?} id="inventory-ai-settings" class="card bg-base-100 shadow-sm">
        <div class="card-body p-4 gap-4">
          <div>
            <h2 class="text-base font-semibold">
              {dgettext("default", "AI: inventory from photos")}
            </h2>
            <p class="text-sm text-base-content/60">
              {dgettext(
                "default",
                "A stocktake draft can suggest the items and counts seen on photos. The photos go to the AI provider of the chosen endpoint."
              )}
            </p>
          </div>

          <form
            id="inventory-ai-settings-form"
            phx-submit="save_inventory_ai"
            class="flex flex-col gap-3 max-w-md"
          >
            <div class="flex flex-col gap-1">
              <.select
                id="inventory-ai-endpoint"
                name="inventory_ai[endpoint_uuid]"
                label={dgettext("default", "AI endpoint")}
                prompt={dgettext("default", "Not set")}
                value={@inventory_ai_endpoint_uuid}
                options={for o <- @inventory_ai_options, do: {endpoint_label(o), o.uuid}}
                class="select-sm"
              />
              <span id="inventory-ai-endpoint-hint" class="text-xs text-base-content/50">
                {dgettext("default", "Pick a model that can read photos.")}
                {dgettext("default", "Without an endpoint the button is not shown.")}
              </span>
            </div>

            <.decimal_input
              id="inventory-ai-max-photos"
              name="inventory_ai[max_photos]"
              label={dgettext("default", "Photos in one batch")}
              value={@inventory_ai_max_photos}
              class="input-sm"
            />

            <.decimal_input
              id="inventory-ai-max-items"
              name="inventory_ai[max_items]"
              label={dgettext("default", "Most catalogue lines in one request")}
              value={@inventory_ai_max_items}
              class="input-sm"
            />

            <p class="text-xs text-base-content/50">
              <.pk_link id="inventory-ai-prompt-link" navigate={@inventory_ai_prompt_path} class="link">
                {dgettext("default", "Edit the prompt")}
              </.pk_link>
            </p>

            <p :if={@inventory_ai_error} id="inventory-ai-settings-error" class="text-sm text-error">
              {@inventory_ai_error}
            </p>
            <p :if={@inventory_ai_saved?} id="inventory-ai-settings-saved" class="text-sm text-success">
              {dgettext("default", "Saved.")}
            </p>

            <div>
              <.button type="submit" variant="primary" size="sm">
                {dgettext("default", "Save")}
              </.button>
            </div>
          </form>
        </div>
      </div>
    </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
