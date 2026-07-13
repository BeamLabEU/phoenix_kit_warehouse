defmodule PhoenixKitWarehouse.Web.TurnoverReportLive do
  @moduledoc """
  LiveView for the Warehouse "Turnover" report (§8, no export).

  A simple, fixed-column report — deliberately NOT built on the
  table-parity stack (`ColumnManagement`/`ColumnConfig`): a six-field
  movement report has no per-user column-personalization need. Renders a
  `date_from`/`date_to` + warehouse-scope filter form (single
  `phx-change="filter_change"` covering all three fields, defaulting to
  the current calendar month and every warehouse) on top of
  `PhoenixKitWarehouse.Turnover.compute/3`.

  The "Balance" column is each item's **current** on-hand quantity, not a
  historical balance as of `date_to` (see `Turnover`'s moduledoc for why —
  there's no ledger/journal table to reconstruct a point-in-time balance
  from). That limitation is surfaced twice in the UI, not just in code: an
  always-visible caption under the filter form (works without hover, so it
  reaches touch/mobile users too) and an info-icon tooltip on the column
  header itself.

  Admin-chrome pattern: self-wrapping render with `LayoutWrapper.app_layout`
  (see `:self_wrapped_layout` on_mount), same as `StockLive`/`TransferIndexLive`.
  Navigation via `PhoenixKit.Utils.Routes.path/1`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Turnover
  alias PhoenixKitWarehouse.Web.Components.WarehouseHeader

  # Opt out of PhoenixKit's auto admin-chrome layout so this view self-wraps
  # with `LayoutWrapper.app_layout` in render/1. Same pattern as StockLive.
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()

    socket =
      socket
      |> assign(:page_title, dgettext("default", "Warehouse"))
      |> assign(:date_from, Date.beginning_of_month(today))
      |> assign(:date_to, Date.end_of_month(today))
      |> assign(:location_uuid, nil)
      |> assign(:warehouses, [])
      |> assign(:rows, [])

    {:ok, socket}
  end

  # mount/3 is called twice (disconnected HTTP render + connected WebSocket
  # mount) — the report query and list_warehouses/0 belong here, run once
  # per navigation, same split as StockLive.
  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      socket
      |> assign(:warehouses, StockLedger.list_warehouses())
      |> assign_rows()

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  # Single handler for the whole filter form (date_from + date_to +
  # location_uuid) — a native `<form phx-change>` always serializes every
  # field, not just the one the keeper touched, so one event covers all
  # three inputs at once.
  @impl true
  def handle_event("filter_change", params, socket) do
    socket =
      socket
      |> assign(:date_from, parse_date(params["date_from"], socket.assigns.date_from))
      |> assign(:date_to, parse_date(params["date_to"], socket.assigns.date_to))
      |> assign(:location_uuid, normalize_location(params["location_uuid"]))
      |> assign_rows()

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Pipeline
  # ---------------------------------------------------------------------------

  defp assign_rows(socket) do
    rows =
      Turnover.compute(
        socket.assigns.location_uuid,
        socket.assigns.date_from,
        socket.assigns.date_to
      )

    assign(socket, :rows, rows)
  end

  # A blank/missing date keeps the previous value rather than crashing —
  # the keeper is mid-edit (e.g. cleared the field before typing a new one).
  defp parse_date(v, fallback) when v in [nil, ""], do: fallback

  defp parse_date(str, fallback) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      {:error, _} -> fallback
    end
  end

  # "" is the <select>'s "All warehouses" option value.
  defp normalize_location(v) when v in [nil, ""], do: nil
  defp normalize_location(v), do: v

  # Hides the warehouse <select> entirely when no warehouse LocationType is
  # configured — matches `StockLive`'s `warehouse_options?/1` convention. An
  # unconfigured type means `list_warehouses/0` returns `nil`, and a select
  # with only an "All warehouses" option would offer no real choice.
  defp warehouse_options?(nil), do: false
  defp warehouse_options?([]), do: false
  defp warehouse_options?(_), do: true

  defp fmt_qty(%Decimal{} = d), do: Decimal.to_string(d, :normal)

  defp emdash(nil), do: "—"
  defp emdash(""), do: "—"
  defp emdash(v), do: v

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={dgettext("default", "Warehouse")}
      current_path={
        assigns[:url_path] || assigns[:current_path] ||
          PhoenixKit.Utils.Routes.path("/admin/warehouse")
      }
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col mx-auto max-w-none sm:px-4 py-2 sm:py-6 gap-2">
        <WarehouseHeader.warehouse_header active={:turnover} />

        <form id="turnover-filters" phx-change="filter_change" class="flex flex-wrap items-end gap-3">
          <div class="flex flex-col gap-1">
            <label class="text-xs font-medium text-base-content/60">
              {dgettext("default", "From")}
            </label>
            <input
              type="date"
              name="date_from"
              value={Date.to_iso8601(@date_from)}
              class="input input-sm input-bordered"
            />
          </div>
          <div class="flex flex-col gap-1">
            <label class="text-xs font-medium text-base-content/60">
              {dgettext("default", "To")}
            </label>
            <input
              type="date"
              name="date_to"
              value={Date.to_iso8601(@date_to)}
              class="input input-sm input-bordered"
            />
          </div>
          <div :if={warehouse_options?(@warehouses)} class="flex flex-col gap-1">
            <label class="text-xs font-medium text-base-content/60">
              {dgettext("default", "Warehouse")}
            </label>
            <select name="location_uuid" class="select select-sm select-bordered">
              <option value="" selected={@location_uuid == nil}>
                {dgettext("default", "All warehouses")}
              </option>
              <%= for warehouse <- @warehouses do %>
                <option value={warehouse.uuid} selected={@location_uuid == warehouse.uuid}>
                  {warehouse.name}
                </option>
              <% end %>
            </select>
          </div>
        </form>

        <p class="text-xs text-base-content/50">
          {dgettext(
            "default",
            "Balance shows each item's current stock, not a historical balance as of the selected end date."
          )}
        </p>

        <.table_default
          id="turnover-table"
          variant="zebra"
          size="sm"
          toggleable
          items={@rows}
          card_class="card card-sm bg-base-200 shadow-sm"
          card_fields={
            fn row ->
              [
                %{label: dgettext("default", "SKU"), value: emdash(row.sku)},
                %{label: dgettext("default", "Unit"), value: emdash(row.unit)},
                %{label: dgettext("default", "Inflow"), value: fmt_qty(row.inflow)},
                %{label: dgettext("default", "Outflow"), value: fmt_qty(row.outflow)},
                %{label: dgettext("default", "Balance"), value: fmt_qty(row.balance)}
              ]
            end
          }
        >
          <:card_header :let={row}>
            <span class="font-medium text-sm">{row.name}</span>
          </:card_header>

          <.table_default_header>
            <.table_default_row hover={false}>
              <.table_default_header_cell>{dgettext("default", "Item")}</.table_default_header_cell>
              <.table_default_header_cell>{dgettext("default", "SKU")}</.table_default_header_cell>
              <.table_default_header_cell>{dgettext("default", "Unit")}</.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {dgettext("default", "Inflow")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {dgettext("default", "Outflow")}
              </.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                <span class="inline-flex items-center justify-end gap-1">
                  {dgettext("default", "Balance")}
                  <span
                    class="tooltip tooltip-left"
                    data-tip={
                      dgettext(
                        "default",
                        "Current on-hand quantity — not a historical balance as of the end date."
                      )
                    }
                  >
                    <.icon name="hero-information-circle" class="w-3.5 h-3.5 text-base-content/40" />
                  </span>
                </span>
              </.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>

          <.table_default_body>
            <%= if @rows == [] do %>
              <.table_default_row hover={false}>
                <.table_default_cell colspan={6} class="text-center py-10 text-base-content/50">
                  <.icon name="hero-chart-bar" class="h-10 w-10 mx-auto mb-2 opacity-50" />
                  <div class="text-sm font-medium">
                    {dgettext("default", "No movement in this period")}
                  </div>
                </.table_default_cell>
              </.table_default_row>
            <% end %>
            <%= for row <- @rows do %>
              <.table_default_row>
                <.table_default_cell class="text-sm">{row.name}</.table_default_cell>
                <.table_default_cell class="text-sm">{emdash(row.sku)}</.table_default_cell>
                <.table_default_cell class="text-sm">{emdash(row.unit)}</.table_default_cell>
                <.table_default_cell class="text-right text-sm">
                  {fmt_qty(row.inflow)}
                </.table_default_cell>
                <.table_default_cell class="text-right text-sm">
                  {fmt_qty(row.outflow)}
                </.table_default_cell>
                <.table_default_cell class="text-right text-sm font-medium">
                  {fmt_qty(row.balance)}
                </.table_default_cell>
              </.table_default_row>
            <% end %>
          </.table_default_body>
        </.table_default>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
