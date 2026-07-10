defmodule PhoenixKitWarehouse.Web.InternalOrderIndexLive do
  @moduledoc """
  LiveView for the Internal Orders list page.

  Admin-chrome pattern: `use PhoenixKitWeb, :live_view`, self-wrapping render/1
  with `LayoutWrapper.app_layout`. Navigation via `PhoenixKit.Utils.Routes.path/1`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  use PhoenixKitWarehouse.Web.ColumnManagement,
    column_config: PhoenixKitWarehouse.ColumnConfig.InternalOrders,
    scope: "warehouse_internal_orders"

  alias PhoenixKitWarehouse.{DocRefs, InternalOrders}
  alias PhoenixKitWarehouse.ColumnConfig.InternalOrders, as: InternalOrderColumnConfig
  alias PhoenixKitWarehouse.Web.Components.{ColumnModal, FilterChips, WarehouseHeader}

  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    current_user = scope && PhoenixKit.Users.Auth.Scope.user(scope)
    user_uuid = current_user && current_user.uuid

    socket =
      socket
      |> assign(:page_title, dgettext("default", "Warehouse"))
      |> assign(:search, "")
      |> assign(:sort_by, "number")
      |> assign(:sort_dir, :desc)
      |> assign(:current_user_uuid, user_uuid)
      |> assign(:orders, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      socket
      |> PhoenixKitWarehouse.Web.ColumnManagement.assign_column_state(InternalOrderColumnConfig)
      |> assign_orders()

    {:noreply, socket}
  end

  def __view_config_changed__(socket) do
    socket =
      if socket.assigns.sort_by in socket.assigns.selected_columns do
        socket
      else
        assign(socket, :sort_by, List.first(socket.assigns.selected_columns) || "number")
      end

    assign_orders(socket)
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(:search, search) |> assign_orders()}
  end

  @impl true
  def handle_event("set_sort", %{"sort_by" => by}, socket) do
    {:noreply, socket |> assign(:sort_by, parse_sort_by(by)) |> assign_orders()}
  end

  @impl true
  def handle_event("toggle_sort", %{"by" => by}, socket) do
    by_id = parse_sort_by(by)

    {sort_by, sort_dir} =
      if socket.assigns.sort_by == by_id,
        do: {by_id, flip_dir(socket.assigns.sort_dir)},
        else: {by_id, default_dir(by_id)}

    {:noreply,
     socket |> assign(:sort_by, sort_by) |> assign(:sort_dir, sort_dir) |> assign_orders()}
  end

  @impl true
  def handle_event("flip_sort_dir", _params, socket) do
    {:noreply, socket |> assign(:sort_dir, flip_dir(socket.assigns.sort_dir)) |> assign_orders()}
  end

  # ---------------------------------------------------------------------------
  # Pipeline
  # ---------------------------------------------------------------------------

  defp assign_orders(socket) do
    orders =
      InternalOrders.list_internal_orders()
      |> enrich_orders()
      |> apply_global_search(socket.assigns.search)
      |> apply_column_filters(socket.assigns.active_filters, socket.assigns.filter_values)
      |> apply_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    assign(socket, :orders, orders)
  end

  defp enrich_orders(orders) do
    orders_with_sub = Enum.map(orders, &{&1, sub_order_uuid_of(&1)})

    sub_order_uuids =
      orders_with_sub |> Enum.map(&elem(&1, 1)) |> Enum.filter(& &1) |> Enum.uniq()

    sub_order_refs = DocRefs.sub_order_refs(sub_order_uuids)

    Enum.map(orders_with_sub, fn {order, sub_order_uuid} ->
      sub_ref = Map.get(sub_order_refs, sub_order_uuid)

      %{
        uuid: order.uuid,
        number: order.number,
        status: order.status,
        status_label: status_label(order.status),
        sub_order_uuid: sub_order_uuid,
        sub_order_ref: sub_ref,
        location_uuid: order.location_uuid,
        inserted_at: order.inserted_at,
        posted_at: order.posted_at,
        note: order.note,
        lines_count: length(order.lines || [])
      }
    end)
  end

  defp sub_order_uuid_of(%{source_refs: refs}) do
    Enum.find_value(refs || [], fn
      %{"type" => "sub_order", "uuid" => uuid} -> uuid
      _ -> nil
    end)
  end

  defp apply_global_search(entries, ""), do: entries

  defp apply_global_search(entries, query) do
    q = String.downcase(query)

    Enum.filter(entries, fn e ->
      String.downcase(to_string(e.number)) |> String.contains?(q) or
        String.downcase(e.note || "") |> String.contains?(q)
    end)
  end

  defp apply_column_filters(entries, active_filters, filter_values) do
    meta_map = InternalOrderColumnConfig.column_metadata_map()

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
    case Map.get(InternalOrderColumnConfig.column_metadata_map(), value) do
      %{sortable?: true} -> value
      _ -> "number"
    end
  end

  defp parse_sort_by(value) when is_atom(value), do: parse_sort_by(Atom.to_string(value))
  defp parse_sort_by(_), do: "number"

  defp flip_dir(:asc), do: :desc
  defp flip_dir(_), do: :asc

  defp default_dir(column_id) do
    case Map.get(InternalOrderColumnConfig.column_metadata_map(), column_id) do
      %{default_dir: dir} -> dir
      _ -> :asc
    end
  end

  defp apply_sort(entries, by, dir) do
    case Map.get(InternalOrderColumnConfig.column_metadata_map(), by) do
      %{sort_key: key_fn} when is_function(key_fn, 1) -> Enum.sort_by(entries, key_fn, dir)
      _ -> entries
    end
  end

  defp sortable_visible(selected_columns) do
    meta_map = InternalOrderColumnConfig.column_metadata_map()

    selected_columns
    |> Enum.map(&Map.get(meta_map, &1))
    |> Enum.filter(&(&1 && &1.sortable?))
  end

  defp status_label("draft"), do: dgettext("default", "Draft")
  defp status_label("posted"), do: dgettext("default", "Posted")
  defp status_label(other), do: other

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
        <WarehouseHeader.warehouse_header active={:internal_orders} />

        <.table_default
          id="internal-orders-table"
          variant="zebra"
          size="sm"
          toggleable
          items={@orders}
          card_class="card card-sm bg-base-200 shadow-sm"
          card_fields={
            fn entry ->
              meta_map = InternalOrderColumnConfig.column_metadata_map()

              Enum.map(@selected_columns, fn col ->
                %{label: column_label(meta_map, col), value: render_card_value(col, entry)}
              end)
            end
          }
        >
          <:toolbar_title>
            <div class="flex flex-wrap items-center gap-2">
              <form id="io-search" phx-change="search" class="contents">
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
                        meta = Map.get(InternalOrderColumnConfig.column_metadata_map(), id),
                        meta do %>
                <FilterChips.filter_chip
                  meta={meta}
                  value={Map.get(@filter_values, id)}
                  entries={@orders}
                />
              <% end %>
            </div>
          </:toolbar_title>

          <:toolbar_actions>
            <.link
              navigate={PhoenixKit.Utils.Routes.path("/admin/warehouse/internal-orders/new")}
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-plus" class="w-4 h-4" />
              {dgettext("default", "New internal order")}
            </.link>

            <span class="text-sm text-base-content/70 whitespace-nowrap">
              {dgettext("default", "Sort by:")}
            </span>
            <form id="io-sort" phx-change="set_sort" class="join">
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
            <.link
              navigate={
                PhoenixKit.Utils.Routes.path("/admin/warehouse/internal-orders/#{entry.uuid}")
              }
              class="font-medium font-mono text-sm after:absolute after:inset-0 after:z-0"
            >
              #IO-{entry.number}
            </.link>
            <span class={[
              "badge badge-sm",
              entry.status == "posted" && "badge-success",
              entry.status == "draft" && "badge-ghost"
            ]}>
              {entry.status_label}
            </span>
          </:card_header>

          <.table_default_header>
            <.table_default_row hover={false}>
              <% meta_map = InternalOrderColumnConfig.column_metadata_map() %>
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
              <.table_default_header_cell class="w-12"></.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>

          <.table_default_body>
            <%= if @orders == [] do %>
              <.table_default_row hover={false}>
                <.table_default_cell
                  colspan={length(@selected_columns) + 1}
                  class="text-center py-10 text-base-content/50"
                >
                  <.icon name="hero-arrow-right-circle" class="h-10 w-10 mx-auto mb-2 opacity-50" />
                  <div class="text-sm font-medium">{dgettext("default", "No internal orders yet")}</div>
                </.table_default_cell>
              </.table_default_row>
            <% end %>
            <%= for entry <- @orders do %>
              <.table_default_row class="relative cursor-pointer">
                <% meta_map = InternalOrderColumnConfig.column_metadata_map() %>
                <%= for col <- @selected_columns, meta = Map.get(meta_map, col), meta do %>
                  <.table_default_cell class={cell_class(col, meta)}>
                    {render_cell(col, entry)}
                  </.table_default_cell>
                <% end %>
                <.table_default_cell class="relative z-10 w-12">
                  <.table_row_menu id={"io-menu-#{entry.uuid}"}>
                    <.table_row_menu_link
                      navigate={
                        PhoenixKit.Utils.Routes.path(
                          "/admin/warehouse/internal-orders/#{entry.uuid}"
                        )
                      }
                      icon="hero-pencil-square"
                      label={dgettext("default", "Edit")}
                    />
                  </.table_row_menu>
                </.table_default_cell>
              </.table_default_row>
            <% end %>
          </.table_default_body>
        </.table_default>

        <ColumnModal.column_modal
          show={@show_column_modal}
          column_config={InternalOrderColumnConfig}
          selected={@selected_columns}
          active_filters={@active_filters}
          temp_selected={@temp_selected_columns}
          temp_active_filters={@temp_active_filters}
        />
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

  defp cell_class("number", _meta), do: ""
  defp cell_class(_col, %{align: :right}), do: "text-right text-sm"
  defp cell_class(_col, _meta), do: "text-sm"

  defp render_cell("number", entry) do
    assigns = %{entry: entry}

    ~H"""
    <.link
      navigate={PhoenixKit.Utils.Routes.path("/admin/warehouse/internal-orders/#{@entry.uuid}")}
      class="font-medium font-mono after:absolute after:inset-0 after:z-0"
    >
      #IO-{@entry.number}
    </.link>
    """
  end

  defp render_cell("date", entry), do: fmt_date(entry.inserted_at)
  defp render_cell("posted_at", entry), do: fmt_date(entry.posted_at)
  defp render_cell("lines_count", entry), do: entry.lines_count

  defp render_cell("sub_order", entry) do
    case entry.sub_order_ref do
      nil ->
        "—"

      ref ->
        assigns = %{ref: ref}

        ~H"""
        <.link navigate={@ref.path} class="link link-primary font-mono text-sm after:hidden">
          {@ref.label}
        </.link>
        """
    end
  end

  defp render_cell("note", entry), do: emdash(entry.note)

  defp render_cell("status", entry) do
    assigns = %{entry: entry}

    ~H"""
    <span class={[
      "badge badge-sm",
      @entry.status == "posted" && "badge-success",
      @entry.status == "draft" && "badge-ghost"
    ]}>
      {@entry.status_label}
    </span>
    """
  end

  defp render_cell(_col, _entry), do: "—"

  defp render_card_value("status", entry) do
    assigns = %{entry: entry}

    ~H"""
    <span class={[
      "badge badge-sm",
      @entry.status == "posted" && "badge-success",
      @entry.status == "draft" && "badge-ghost"
    ]}>
      {@entry.status_label}
    </span>
    """
  end

  defp render_card_value("number", entry), do: "#IO-#{entry.number}"
  defp render_card_value("date", entry), do: fmt_date(entry.inserted_at)
  defp render_card_value("posted_at", entry), do: fmt_date(entry.posted_at)
  defp render_card_value("lines_count", entry), do: entry.lines_count

  defp render_card_value("sub_order", entry) do
    case entry.sub_order_ref do
      nil -> "—"
      ref -> ref.label
    end
  end

  defp render_card_value("note", entry), do: emdash(entry.note)
  defp render_card_value(_col, _entry), do: "—"

  defp fmt_date(nil), do: "—"
  defp fmt_date(dt), do: Calendar.strftime(dt, "%d.%m.%Y")

  defp emdash(nil), do: "—"
  defp emdash(""), do: "—"
  defp emdash(v), do: v
end
