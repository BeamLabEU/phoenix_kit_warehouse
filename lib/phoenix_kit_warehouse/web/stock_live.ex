defmodule PhoenixKitWarehouse.Web.StockLive do
  @moduledoc """
  LiveView for the Warehouse "In stock" page.

  Two views, toggled per-user:
  - **Grouped** (default): read-only catalogue/category tree via
    `WarehouseBrowser.stock_sheet`.
  - **Flat**: full table-parity view backed by `Andi.Warehouse.StockColumnConfig`
    — global search, per-column filtering, sorting, and configurable columns.

  Admin-chrome pattern: self-wrapping render with `LayoutWrapper.app_layout`
  so the page title lands in the global admin header (see `:self_wrapped_layout`
  on_mount). Navigation via `PhoenixKit.Utils.Routes.path/1`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  use PhoenixKitWarehouse.Web.ColumnManagement,
    column_config: PhoenixKitWarehouse.ColumnConfig.Stock,
    scope: "warehouse_stock"

  import PhoenixKitBilling.Web.Components.CurrencyDisplay, only: [currency_compact: 1]

  alias PhoenixKitWarehouse.ViewConfigs
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.ColumnConfig.Stock, as: StockColumnConfig

  alias PhoenixKitWarehouse.Web.Components.{
    ColumnModal,
    FilterChips,
    WarehouseBrowser,
    WarehouseHeader
  }

  alias PhoenixKitCatalogue.Catalogue

  # Opt out of PhoenixKit's auto admin-chrome layout so this view self-wraps
  # with `LayoutWrapper.app_layout` in render/1. Same pattern as orders/index.ex.
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(_params, _session, socket) do
    locale = socket.assigns[:current_locale] || Gettext.get_locale()

    scope = socket.assigns[:phoenix_kit_current_scope]
    current_user = scope && PhoenixKit.Users.Auth.Scope.user(scope)
    user_uuid = current_user && current_user.uuid

    socket =
      socket
      |> assign(:page_title, dgettext("default", "Warehouse"))
      |> assign(:locale, locale)
      |> assign(:stock_items, [])
      |> assign(:stock_view, "grouped")
      |> assign(:search, "")
      |> assign(:sort_by, "item")
      |> assign(:sort_dir, :asc)
      |> assign(:current_user_uuid, user_uuid)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    user_uuid = socket.assigns.current_user_uuid

    stock_view =
      (is_binary(user_uuid) &&
         Map.get(ViewConfigs.get_view_config(user_uuid, "warehouse_stock"), "stock_view")) ||
        "grouped"

    # Computed once here (was: once for `:stock_items` in mount, then again
    # inside assign_stock_rows/1 — 2x per mount cycle). assign_stock_rows/2
    # reuses this result instead of re-querying.
    items = build_stock_items()

    socket =
      socket
      |> assign(:stock_view, stock_view)
      |> assign(:stock_items, items)
      |> PhoenixKitWarehouse.Web.ColumnManagement.assign_column_state(StockColumnConfig)
      |> assign_stock_rows(items)

    {:noreply, socket}
  end

  # Re-run the pipeline after a filter value change or a column save (called by
  # the ColumnManagement macro); reset sort if its column was hidden.
  def __view_config_changed__(socket) do
    socket =
      if socket.assigns.sort_by in socket.assigns.selected_columns do
        socket
      else
        assign(socket, :sort_by, List.first(socket.assigns.selected_columns) || "item")
      end

    assign_stock_rows(socket)
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("set_stock_view", %{"view" => v}, socket) when v in ["grouped", "flat"] do
    uuid = socket.assigns.current_user_uuid

    if is_binary(uuid) do
      ViewConfigs.merge_view_config(uuid, "warehouse_stock", %{"stock_view" => v})
    end

    {:noreply, assign(socket, :stock_view, v)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(:search, search) |> assign_stock_rows()}
  end

  @impl true
  def handle_event("set_sort", %{"sort_by" => by}, socket) do
    {:noreply, socket |> assign(:sort_by, parse_sort_by(by)) |> assign_stock_rows()}
  end

  @impl true
  def handle_event("toggle_sort", %{"by" => by}, socket) do
    by_id = parse_sort_by(by)

    {sort_by, sort_dir} =
      if socket.assigns.sort_by == by_id,
        do: {by_id, flip_dir(socket.assigns.sort_dir)},
        else: {by_id, default_dir(by_id)}

    {:noreply,
     socket |> assign(:sort_by, sort_by) |> assign(:sort_dir, sort_dir) |> assign_stock_rows()}
  end

  @impl true
  def handle_event("flip_sort_dir", _params, socket) do
    {:noreply,
     socket |> assign(:sort_dir, flip_dir(socket.assigns.sort_dir)) |> assign_stock_rows()}
  end

  # ---------------------------------------------------------------------------
  # Pipeline
  # ---------------------------------------------------------------------------

  # Re-queries current stock — used by search/sort/filter event handlers,
  # which should reflect any stock changes since the page loaded.
  defp assign_stock_rows(socket), do: assign_stock_rows(socket, build_stock_items())

  # Builds :stock_rows from an already-fetched item list — used by
  # handle_params/3, which fetches `items` once for both :stock_items and
  # :stock_rows instead of querying twice.
  defp assign_stock_rows(socket, items) do
    locale = socket.assigns.locale

    rows =
      items
      |> enrich_stock(locale)
      |> apply_global_search(socket.assigns.search)
      |> apply_column_filters(socket.assigns.active_filters, socket.assigns.filter_values)
      |> apply_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    assign(socket, :stock_rows, rows)
  end

  defp enrich_stock(items, locale) do
    Enum.map(items, fn %{item: item, quantity: q, unit_value: uv} ->
      catalogue_name =
        (item.catalogue &&
           WarehouseBrowser.localized_name(item.catalogue, locale)
           |> WarehouseBrowser.strip_prefix()) ||
          ""

      %{
        item: item,
        display_name: WarehouseBrowser.localized_name(item, locale),
        sku: item.sku,
        catalogue_name: catalogue_name,
        category_name:
          (item.category && WarehouseBrowser.localized_name(item.category, locale)) || "",
        unit_label: WarehouseBrowser.unit_label(item.unit),
        quantity: q,
        unit_value: uv,
        total_value: uv && Decimal.mult(q, uv)
      }
    end)
  end

  defp apply_global_search(entries, ""), do: entries

  defp apply_global_search(entries, query) do
    q = String.downcase(query)

    Enum.filter(entries, fn e ->
      String.downcase(e.display_name || "") |> String.contains?(q) or
        String.downcase(e.sku || "") |> String.contains?(q)
    end)
  end

  defp apply_column_filters(entries, active_filters, filter_values) do
    meta_map = StockColumnConfig.column_metadata_map()

    Enum.reduce(active_filters, entries, fn id, acc ->
      meta = Map.get(meta_map, id)
      value = Map.get(filter_values, id)

      cond do
        is_nil(meta) -> acc
        is_nil(value) -> acc
        true -> meta.filter_apply.(acc, value)
      end
    end)
  end

  defp parse_sort_by(value) when is_binary(value) do
    case Map.get(StockColumnConfig.column_metadata_map(), value) do
      %{sortable?: true} -> value
      _ -> "item"
    end
  end

  defp parse_sort_by(value) when is_atom(value), do: parse_sort_by(Atom.to_string(value))
  defp parse_sort_by(_), do: "item"

  defp flip_dir(:asc), do: :desc
  defp flip_dir(_), do: :asc

  defp default_dir(column_id) do
    case Map.get(StockColumnConfig.column_metadata_map(), column_id) do
      %{default_dir: dir} -> dir
      _ -> :asc
    end
  end

  defp apply_sort(entries, by, dir) do
    case Map.get(StockColumnConfig.column_metadata_map(), by) do
      %{sort_key: key_fn} when is_function(key_fn, 1) -> Enum.sort_by(entries, key_fn, dir)
      _ -> entries
    end
  end

  defp sortable_visible(selected_columns) do
    meta_map = StockColumnConfig.column_metadata_map()

    selected_columns
    |> Enum.map(&Map.get(meta_map, &1))
    |> Enum.filter(&(&1 && &1.sortable?))
  end

  # ---------------------------------------------------------------------------
  # Private helpers — stock items (used by both views)
  # ---------------------------------------------------------------------------

  # Items with a non-zero balance, preloaded with catalogue/category. Used as
  # source for both the grouped view (stock_items) and the flat pipeline.
  defp build_stock_items do
    stock_map = StockLedger.stock_map()

    uuids =
      stock_map
      |> Enum.filter(fn {_uuid, s} -> Decimal.gt?(s.quantity, Decimal.new(0)) end)
      |> Enum.map(&elem(&1, 0))

    Catalogue.list_items_by_uuids(uuids)
    |> Enum.map(fn item ->
      s = Map.fetch!(stock_map, item.uuid)
      %{item: item, quantity: s.quantity, unit_value: s.unit_value}
    end)
    |> Enum.sort_by(fn %{item: item} ->
      {String.downcase((item.catalogue && item.catalogue.name) || ""),
       String.downcase((item.category && item.category.name) || ""),
       String.downcase(item.name || "")}
    end)
  end

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
        <WarehouseHeader.warehouse_header active={:stock} />

        <%!-- Grouped / Flat toggle --%>
        <div class="flex items-center gap-2 mb-1">
          <div class="join">
            <button
              type="button"
              class={[
                "btn btn-sm join-item",
                @stock_view == "grouped" && "btn-active"
              ]}
              phx-click="set_stock_view"
              phx-value-view="grouped"
            >
              {dgettext("default", "Grouped")}
            </button>
            <button
              type="button"
              class={[
                "btn btn-sm join-item",
                @stock_view == "flat" && "btn-active"
              ]}
              phx-click="set_stock_view"
              phx-value-view="flat"
            >
              {dgettext("default", "Flat")}
            </button>
          </div>
        </div>

        <%= if @stock_view == "flat" do %>
          <%!-- Flat view: full table parity --%>
          <.table_default
            id="stock-table"
            variant="zebra"
            size="sm"
            toggleable
            items={@stock_rows}
            card_class="card card-sm bg-base-200 shadow-sm"
            card_fields={
              fn entry ->
                meta_map = StockColumnConfig.column_metadata_map()

                Enum.map(@selected_columns, fn col ->
                  %{label: column_label(meta_map, col), value: render_card_value(col, entry)}
                end)
              end
            }
          >
            <:toolbar_title>
              <div class="flex flex-wrap items-center gap-2">
                <form id="stock-search" phx-change="search" class="contents">
                  <label class="input input-sm w-full sm:w-64">
                    <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-50" />
                    <input
                      type="search"
                      name="search"
                      value={@search}
                      placeholder={dgettext("default", "Search...")}
                      class="grow"
                      phx-debounce="300"
                    />
                  </label>
                </form>

                <%= for id <- @active_filters,
                        meta = Map.get(StockColumnConfig.column_metadata_map(), id),
                        meta do %>
                  <FilterChips.filter_chip
                    meta={meta}
                    value={Map.get(@filter_values, id)}
                    entries={@stock_rows}
                  />
                <% end %>
              </div>
            </:toolbar_title>

            <:toolbar_actions>
              <span class="text-sm text-base-content/70 whitespace-nowrap">
                {dgettext("default", "Sort by:")}
              </span>
              <form id="stock-sort" phx-change="set_sort" class="join">
                <select name="sort_by" class="select select-sm join-item">
                  <%= for meta <- sortable_visible(@selected_columns) do %>
                    <option value={meta.id} selected={@sort_by == meta.id}>{meta.label.()}</option>
                  <% end %>
                </select>
                <button
                  type="button"
                  phx-click="flip_sort_dir"
                  class="btn btn-sm btn-ghost join-item"
                  title={
                    if @sort_dir == :asc,
                      do: dgettext("default", "Ascending"),
                      else: dgettext("default", "Descending")
                  }
                >
                  <.icon
                    name={if @sort_dir == :asc, do: "hero-chevron-up", else: "hero-chevron-down"}
                    class="w-4 h-4"
                  />
                </button>
              </form>

              <button
                type="button"
                class="btn btn-outline btn-sm"
                phx-click="show_column_modal"
                title={dgettext("default", "Customize columns")}
              >
                <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
                <span class="hidden sm:inline">{dgettext("default", "Columns")}</span>
              </button>
            </:toolbar_actions>

            <:card_header :let={entry}>
              <span class="font-medium text-sm">{entry.display_name || "—"}</span>
              <span :if={entry.sku} class="text-xs text-base-content/60 font-mono">{entry.sku}</span>
            </:card_header>

            <.table_default_header>
              <.table_default_row hover={false}>
                <% meta_map = StockColumnConfig.column_metadata_map() %>
                <%= for col <- @selected_columns, meta = Map.get(meta_map, col), meta do %>
                  <.table_default_header_cell class={if meta.align == :right, do: "text-right"}>
                    <%= if meta.sortable? do %>
                      <.sort_header
                        by={meta.id}
                        label={meta.label.()}
                        sort_by={@sort_by}
                        sort_dir={@sort_dir}
                        align={meta.align}
                      />
                    <% else %>
                      {meta.label.()}
                    <% end %>
                  </.table_default_header_cell>
                <% end %>
              </.table_default_row>
            </.table_default_header>

            <.table_default_body>
              <%= if @stock_rows == [] do %>
                <.table_default_row hover={false}>
                  <.table_default_cell
                    colspan={max(length(@selected_columns), 1)}
                    class="text-center py-10 text-base-content/50"
                  >
                    <.icon name="hero-cube" class="h-10 w-10 mx-auto mb-2 opacity-50" />
                    <div class="text-sm font-medium">{dgettext("default", "No items in stock.")}</div>
                  </.table_default_cell>
                </.table_default_row>
              <% end %>
              <%= for row <- @stock_rows do %>
                <.table_default_row class="relative">
                  <% meta_map = StockColumnConfig.column_metadata_map() %>
                  <%= for col <- @selected_columns, meta = Map.get(meta_map, col), meta do %>
                    <.table_default_cell class={cell_class(col, meta)}>
                      {render_cell(col, row)}
                    </.table_default_cell>
                  <% end %>
                </.table_default_row>
              <% end %>
            </.table_default_body>
          </.table_default>

          <ColumnModal.column_modal
            show={@show_column_modal}
            column_config={StockColumnConfig}
            selected={@selected_columns}
            active_filters={@active_filters}
            temp_selected={@temp_selected_columns}
            temp_active_filters={@temp_active_filters}
          />
        <% else %>
          <%!-- Grouped view (default): catalogue → category tree --%>
          <WarehouseBrowser.stock_sheet stock_items={@stock_items} locale={@locale} />
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  attr(:by, :string, required: true)
  attr(:label, :string, required: true)
  attr(:sort_by, :string, required: true)
  attr(:sort_dir, :atom, required: true)
  attr(:align, :atom, default: :left)

  defp sort_header(assigns) do
    assigns = assign(assigns, :active?, assigns.sort_by == assigns.by)

    ~H"""
    <button
      type="button"
      phx-click="toggle_sort"
      phx-value-by={@by}
      class={[
        "inline-flex items-center gap-1 cursor-pointer select-none",
        @align == :right && "justify-end w-full"
      ]}
    >
      <span>{@label}</span>
      <.icon
        :if={@active?}
        name={if @sort_dir == :asc, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini"}
        class="w-3.5 h-3.5"
      />
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # Per-column rendering
  # ---------------------------------------------------------------------------

  defp column_label(meta_map, col) do
    case Map.get(meta_map, col) do
      %{label: label_fn} -> label_fn.()
      _ -> col
    end
  end

  defp cell_class(_col, %{align: :right}), do: "text-right text-sm"
  defp cell_class(_col, _meta), do: "text-sm"

  defp render_cell("item", entry) do
    assigns = %{entry: entry}

    ~H"""
    <div class="font-medium">{@entry.display_name || "—"}</div>
    <div :if={@entry.sku} class="text-xs text-base-content/40 font-mono">{@entry.sku}</div>
    """
  end

  defp render_cell("sku", entry), do: entry.sku || "—"
  defp render_cell("catalogue", entry), do: emdash(entry.catalogue_name)
  defp render_cell("category", entry), do: emdash(entry.category_name)
  defp render_cell("unit", entry), do: emdash(entry.unit_label)

  defp render_cell("quantity", entry) do
    assigns = %{entry: entry}
    ~H"{@entry.quantity}"
  end

  defp render_cell("unit_value", entry) do
    assigns = %{entry: entry}
    ~H[<.currency_compact amount={@entry.unit_value} currency="EUR" />]
  end

  defp render_cell("total_value", entry) do
    assigns = %{entry: entry}
    ~H[<.currency_compact amount={@entry.total_value} currency="EUR" />]
  end

  defp render_cell(_col, _entry), do: "—"

  # Card values: plain text (no row-overlay link).
  defp render_card_value("item", entry), do: entry.display_name || "—"
  defp render_card_value("sku", entry), do: entry.sku || "—"
  defp render_card_value("catalogue", entry), do: emdash(entry.catalogue_name)
  defp render_card_value("category", entry), do: emdash(entry.category_name)
  defp render_card_value("unit", entry), do: emdash(entry.unit_label)
  defp render_card_value("quantity", entry), do: entry.quantity

  defp render_card_value("unit_value", entry) do
    assigns = %{entry: entry}
    ~H[<.currency_compact amount={@entry.unit_value} currency="EUR" />]
  end

  defp render_card_value("total_value", entry) do
    assigns = %{entry: entry}
    ~H[<.currency_compact amount={@entry.total_value} currency="EUR" />]
  end

  defp render_card_value(_col, _entry), do: "—"

  defp emdash(nil), do: "—"
  defp emdash(""), do: "—"
  defp emdash(v), do: v
end
