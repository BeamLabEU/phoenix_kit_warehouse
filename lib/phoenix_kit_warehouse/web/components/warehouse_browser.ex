defmodule PhoenixKitWarehouse.Web.Components.WarehouseBrowser do
  @moduledoc """
  Warehouse-specific catalogue tree components.

  Three stateless function components driven by assigns from the parent LiveView:

  - `stock_tree/1` — read-only lazy tree annotated with stock quantity and value.
  - `add_picker/1` — lazy tree with search and an Add action per item, for adding
    positions to an inventory document.
  - `count_sheet/1` — editable table of inventory document lines grouped by
    catalogue → category, with conditional price/sum columns.

  Tree toggle state (`expanded_catalogues`, `expanded_categories`,
  `loaded_categories`, `loaded_items`) lives in the parent LV. These components
  are stateless — they only render.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import PhoenixKitBilling.Web.Components.CurrencyDisplay, only: [currency_compact: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]
  import PhoenixKitCatalogue.Web.Components, only: [search_input: 1]

  alias PhoenixKitCatalogue.Catalogue

  # ---------------------------------------------------------------------------
  # stock_tree/1
  # ---------------------------------------------------------------------------

  @doc """
  Read-only lazy catalogue tree annotated with stock quantity and total value.

  Each item row shows:
  - Quantity in stock (with unit label)
  - Total value (`quantity * unit_value`) — only when `unit_value` is known;
    otherwise shows a `—` placeholder.

  Toggle events (`toggle_catalogue` / `toggle_category`) are sent to the
  parent LiveView which updates `expanded_*` and `loaded_*` assigns.
  """
  attr(:catalogue_summaries, :list, required: true)
  attr(:expanded_catalogues, :any, required: true)
  attr(:expanded_categories, :any, required: true)
  attr(:loaded_categories, :map, required: true)
  attr(:loaded_items, :map, required: true)
  attr(:locale, :string, required: true)
  attr(:stock_map, :map, required: true)

  def stock_tree(assigns) do
    ~H"""
    <div>
      <%= if @catalogue_summaries == [] do %>
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body">
            <div class="text-center py-8">
              <.icon
                name="hero-building-storefront"
                class="w-12 h-12 mx-auto mb-3 text-base-content/20"
              />
              <p class="text-base-content/60">
                {dgettext("default", "No catalogues available.")}
              </p>
            </div>
          </div>
        </div>
      <% else %>
        <div class="bg-base-300 rounded-box p-1 flex flex-col gap-0.5">
          <%= for %{catalogue: catalogue} <- @catalogue_summaries do %>
            <% cat_expanded = MapSet.member?(@expanded_catalogues, catalogue.uuid) %>
            <div class={[
              "collapse collapse-arrow bg-base-100 shadow !overflow-visible",
              open_class(cat_expanded)
            ]}>
              <div
                class="collapse-title min-h-0 py-2 font-semibold text-base-content/80 flex items-center gap-2 cursor-pointer bg-base-300"
                phx-click="toggle_catalogue"
                phx-value-uuid={catalogue.uuid}
              >
                <.icon name="hero-rectangle-stack" class="w-4 h-4" />
                {catalogue_display_name(catalogue, @locale)}
              </div>
              <%= if cat_expanded do %>
                <div class="collapse-content px-0 pt-0 pb-0">
                  <%= for %{category: category} <- Map.get(@loaded_categories, catalogue.uuid, []) do %>
                    <% cat_key = if category, do: category.uuid, else: "uncategorized" %>
                    <% category_expanded =
                      MapSet.member?(@expanded_categories, {catalogue.uuid, cat_key}) %>
                    <div class={[
                      "collapse collapse-arrow bg-base-200/50 mb-0.5",
                      open_class(category_expanded)
                    ]}>
                      <div
                        class="collapse-title min-h-0 py-1.5 pl-6 font-medium text-sm flex items-center gap-2 cursor-pointer"
                        phx-click="toggle_category"
                        phx-value-catalogue_uuid={catalogue.uuid}
                        phx-value-key={cat_key}
                      >
                        <.icon name="hero-folder" class="w-4 h-4 text-base-content/50" />
                        {if category,
                          do: localized_name(category, @locale),
                          else: dgettext("default", "Uncategorized")}
                      </div>
                      <%= if category_expanded do %>
                        <div class="collapse-content pl-8 pr-2 pt-0 pb-2">
                          <% items = Map.get(@loaded_items, {catalogue.uuid, cat_key}, []) %>
                          <%= if items == [] do %>
                            <p class="text-xs text-base-content/40 py-2 pl-2">
                              {dgettext("default", "No items")}
                            </p>
                          <% else %>
                            <table class="table table-xs w-full">
                              <thead>
                                <tr>
                                  <th>{dgettext("default", "Item")}</th>
                                  <th class="w-24 text-right">{dgettext("default", "Current stock")}</th>
                                  <th class="w-28 text-right">{dgettext("default", "Total value")}</th>
                                </tr>
                              </thead>
                              <tbody>
                                <%= for item <- items do %>
                                  <% stock_entry = Map.get(@stock_map, item.uuid) %>
                                  <% qty = stock_entry && stock_entry.quantity %>
                                  <% unit_value = stock_entry && stock_entry.unit_value %>
                                  <tr class="hover">
                                    <td>
                                      <div class="font-medium">{localized_name(item, @locale)}</div>
                                      <div class="text-xs text-base-content/40 font-mono">
                                        {item.sku}
                                      </div>
                                    </td>
                                    <td class="text-right">
                                      <span class="font-medium tabular-nums">
                                        {format_quantity(qty)}
                                      </span>
                                      <span class="text-base-content/50 text-xs ml-0.5">
                                        {unit_label(item.unit)}
                                      </span>
                                    </td>
                                    <td class="text-right">
                                      <%= if qty && unit_value do %>
                                        <span class="tabular-nums">
                                          <.currency_compact amount={Decimal.mult(qty, unit_value)} currency="EUR" />
                                        </span>
                                      <% else %>
                                        <span class="text-base-content/30">—</span>
                                      <% end %>
                                    </td>
                                  </tr>
                                <% end %>
                              </tbody>
                            </table>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # add_picker/1
  # ---------------------------------------------------------------------------

  @doc """
  Lazy catalogue tree with search input and an Add button per item.

  Used in the inventory form to add catalogue items not yet in the count sheet
  (goods receipt). Items whose UUID is in `present_item_uuids` are shown
  as disabled (already in the sheet). Re-adding a previously removed line is
  allowed — callers should recompute `present_item_uuids` from the live `lines`
  after every add/remove.

  The add button fires a `phx-click` with the event named by `add_event`
  (default `"add_position"`) and `phx-value-item_uuid`.
  """
  attr(:catalogue_summaries, :list, required: true)
  attr(:expanded_catalogues, :any, required: true)
  attr(:expanded_categories, :any, required: true)
  attr(:loaded_categories, :map, required: true)
  attr(:loaded_items, :map, required: true)
  attr(:locale, :string, required: true)
  attr(:present_item_uuids, :any, default: MapSet.new())
  attr(:item_search_query, :string, default: "")
  attr(:item_search_results, :any, default: nil)
  attr(:add_event, :string, default: "add_position")
  attr(:search_mode, :atom, default: :list)

  def add_picker(assigns) do
    ~H"""
    <div>
      <div class="mb-3">
        <.search_input
          query={@item_search_query}
          placeholder={dgettext("default", "Search items by name, SKU...")}
          on_search="picker_search"
          on_clear="picker_search_clear"
        />
      </div>

      <%= if @search_mode == :tree and @catalogue_summaries == [] do %>
        <div class="text-center py-8 text-base-content/50">
          <.icon name="hero-building-storefront" class="w-8 h-8 mx-auto mb-2 opacity-30" />
          <p>{dgettext("default", "No catalogues available.")}</p>
        </div>
      <% end %>

      <%!-- List mode: flat search results only (no catalogue tree) --%>
      <%= if @search_mode == :list do %>
        <%= cond do %>
          <% is_nil(@item_search_results) -> %>
            <div class="text-center py-8 text-base-content/50">
              <.icon name="hero-magnifying-glass" class="w-8 h-8 mx-auto mb-2 opacity-30" />
              <p class="text-sm">
                {dgettext("default", "Type at least 2 characters to search for items.")}
              </p>
            </div>
          <% @item_search_results == [] -> %>
            <div class="text-center py-6 text-base-content/50">
              <.icon name="hero-magnifying-glass" class="w-6 h-6 mx-auto mb-2 opacity-30" />
              <p class="text-sm">{dgettext("default", "No items found")}</p>
            </div>
          <% true -> %>
            <div class="overflow-x-auto bg-base-100 shadow rounded-box">
              <table class="table table-sm">
                <tbody>
                  <%= for item <- @item_search_results do %>
                    <% present? = MapSet.member?(@present_item_uuids, item.uuid) %>
                    <tr class={["hover", present? && "opacity-50"]}>
                      <td>
                        <div class="font-medium">{localized_name(item, @locale)}</div>
                        <div class="text-xs text-base-content/40 font-mono">{item.sku}</div>
                      </td>
                      <td class="text-xs text-base-content/50">
                        {unit_label(item.unit)}
                      </td>
                      <td class="text-right">
                        <button
                          type="button"
                          phx-click={@add_event}
                          phx-value-item_uuid={item.uuid}
                          disabled={present?}
                          class="btn btn-xs btn-outline btn-primary"
                        >
                          + {dgettext("default", "Add")}
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
        <% end %>
      <% end %>

      <%!-- Tree mode: catalogue tree, filtered to matches when searching --%>
      <%= if @search_mode == :tree and @catalogue_summaries != [] do %>
        <% match_uuids =
          if @item_search_results do
            MapSet.new(@item_search_results, & &1.uuid)
          else
            nil
          end %>
        <div class="bg-base-300 rounded-box p-1 flex flex-col gap-0.5">
          <%= for %{catalogue: catalogue} <- @catalogue_summaries do %>
            <% cat_expanded = MapSet.member?(@expanded_catalogues, catalogue.uuid) %>
            <%!-- In tree-filter mode, filter catalogue away if none of its loaded items match --%>
            <% catalogue_visible =
              if match_uuids do
                @loaded_items
                |> Enum.filter(fn {{cat_uuid, _}, _} -> cat_uuid == catalogue.uuid end)
                |> Enum.any?(fn {_, items} ->
                  Enum.any?(items, &MapSet.member?(match_uuids, &1.uuid))
                end) ||
                  Enum.any?(@item_search_results, fn item ->
                    item.catalogue_uuid == catalogue.uuid
                  end)
              else
                true
              end %>
            <%= if catalogue_visible do %>
              <div class={[
                "collapse collapse-arrow bg-base-100 shadow !overflow-visible",
                open_class(cat_expanded || (match_uuids != nil and catalogue_visible))
              ]}>
                <div
                  class="collapse-title min-h-0 py-2 font-semibold text-base-content/80 flex items-center gap-2 cursor-pointer bg-base-300"
                  phx-click="toggle_catalogue"
                  phx-value-uuid={catalogue.uuid}
                >
                  <.icon name="hero-rectangle-stack" class="w-4 h-4" />
                  {catalogue_display_name(catalogue, @locale)}
                </div>
                <%= if cat_expanded || (match_uuids != nil) do %>
                  <div class="collapse-content px-0 pt-0 pb-0">
                    <%= for %{category: category} <- Map.get(@loaded_categories, catalogue.uuid, []) do %>
                      <% cat_key = if category, do: category.uuid, else: "uncategorized" %>
                      <% category_expanded =
                        MapSet.member?(@expanded_categories, {catalogue.uuid, cat_key}) %>
                      <% category_items = Map.get(@loaded_items, {catalogue.uuid, cat_key}, []) %>
                      <%!-- In tree-filter mode, only show categories that have matching items --%>
                      <% category_visible =
                        if match_uuids do
                          Enum.any?(category_items, &MapSet.member?(match_uuids, &1.uuid)) ||
                            (@item_search_results != nil &&
                               Enum.any?(@item_search_results, fn item ->
                                 (is_nil(category) && is_nil(item.category_uuid)) ||
                                   (category != nil && item.category_uuid == category.uuid)
                               end))
                        else
                          true
                        end %>
                      <%= if category_visible do %>
                        <div class={[
                          "collapse collapse-arrow bg-base-200/50 mb-0.5",
                          open_class(category_expanded || match_uuids != nil)
                        ]}>
                          <div
                            class="collapse-title min-h-0 py-1.5 pl-6 font-medium text-sm flex items-center gap-2 cursor-pointer"
                            phx-click="toggle_category"
                            phx-value-catalogue_uuid={catalogue.uuid}
                            phx-value-key={cat_key}
                          >
                            <.icon name="hero-folder" class="w-4 h-4 text-base-content/50" />
                            {if category,
                              do: localized_name(category, @locale),
                              else: dgettext("default", "Uncategorized")}
                          </div>
                          <%= if category_expanded || match_uuids != nil do %>
                            <div class="collapse-content pl-8 pr-2 pt-0 pb-2">
                              <% items = Map.get(@loaded_items, {catalogue.uuid, cat_key}, []) %>
                              <% filtered_items =
                                if match_uuids do
                                  Enum.filter(items, &MapSet.member?(match_uuids, &1.uuid))
                                else
                                  items
                                end %>
                              <%= if filtered_items == [] and is_nil(match_uuids) do %>
                                <p class="text-xs text-base-content/40 py-2 pl-2">
                                  {dgettext("default", "No items")}
                                </p>
                              <% else %>
                                <%= if filtered_items == [] and match_uuids != nil do %>
                                  <p class="text-xs text-base-content/40 py-2 pl-2">
                                    {dgettext("default", "No matching items")}
                                  </p>
                                <% else %>
                                  <table class="table table-xs w-full">
                                    <tbody>
                                      <%= for item <- filtered_items do %>
                                        <% present? = MapSet.member?(@present_item_uuids, item.uuid) %>
                                        <tr class={["hover", present? && "opacity-50"]}>
                                          <td>
                                            <div class={["font-medium", present? && "line-through"]}>
                                              {localized_name(item, @locale)}
                                            </div>
                                            <div class="text-xs text-base-content/40 font-mono">
                                              {item.sku}
                                            </div>
                                          </td>
                                          <td class="text-xs text-base-content/50">
                                            {unit_label(item.unit)}
                                          </td>
                                          <td class="text-right">
                                            <button
                                              type="button"
                                              phx-click={@add_event}
                                              phx-value-item_uuid={item.uuid}
                                              disabled={present?}
                                              class="btn btn-xs btn-outline btn-primary"
                                            >
                                              + {dgettext("default", "Add")}
                                            </button>
                                          </td>
                                        </tr>
                                      <% end %>
                                    </tbody>
                                  </table>
                                <% end %>
                              <% end %>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # count_sheet/1
  # ---------------------------------------------------------------------------

  @doc """
  Editable table of inventory document lines grouped by catalogue → category.

  Each catalogue group is rendered as a DaisyUI collapsible section (open by
  default). Category sub-headers are preserved; each category section ends with
  a `<tfoot>` row showing the quantity subtotal. A quantity subtotal badge is
  also shown in the catalogue-level collapsible header.

  Columns:
  - Name / SKU
  - Unit
  - Current stock (read-only, from `stock_map`)
  - Counted (number input, event `set_counted`)
  - Unit price (event `set_price`) — only when `track_value`
  - Sum (event `set_sum`) — only when `track_value`
  - Remove button (event `remove_line`)

  The `names` map provides localized display names keyed by UUID:
  - item UUID → item name
  - catalogue UUID → catalogue display name
  - category UUID → category name

  Line snapshot names (`line["name"]`) are used as fallback when the UUID
  is not in the map.

  Price/sum columns are hidden entirely when `track_value` is false.
  """
  attr(:lines, :list, required: true)
  attr(:track_value, :boolean, required: true)
  attr(:names, :map, required: true)
  attr(:stock_map, :map, required: true)
  attr(:locale, :string, required: true)
  attr(:editable, :boolean, default: true)

  def count_sheet(assigns) do
    ~H"""
    <div>
      <%= if @lines == [] do %>
        <div class="text-center py-8 text-base-content/50">
          <.icon name="hero-clipboard-document-list" class="w-8 h-8 mx-auto mb-2 opacity-30" />
          <p class="text-sm">
            {dgettext("default", "No lines yet. Add items from the catalogue below.")}
          </p>
        </div>
      <% else %>
        <% grouped = group_lines(@lines) %>
        <div class="flex flex-col gap-2">
          <%= for {catalogue_uuid, catalogue_groups} <- grouped do %>
            <% catalogue_name = resolve_name(@names, catalogue_uuid, nil) %>
            <% catalogue_stock_total =
              Enum.reduce(catalogue_groups, Decimal.new(0), fn {_cat_uuid, cat_lines}, acc ->
                Enum.reduce(cat_lines, acc, fn {_i, line}, inner ->
                  case Map.get(@stock_map, line["item_uuid"]) do
                    %{quantity: q} -> add_decimal(inner, q)
                    _ -> inner
                  end
                end)
              end) %>
            <% catalogue_qty_total =
              Enum.reduce(catalogue_groups, Decimal.new(0), fn {_cat_uuid, cat_lines}, acc ->
                Enum.reduce(cat_lines, acc, fn {_i, line}, inner ->
                  add_decimal(inner, safe_decimal(line["counted_quantity"]))
                end)
              end) %>
            <% catalogue_sum_total =
              Enum.reduce(catalogue_groups, Decimal.new(0), fn {_cat_uuid, cat_lines}, acc ->
                Enum.reduce(cat_lines, acc, fn {_i, line}, inner ->
                  case line_sum(line["counted_quantity"], line["unit_value"]) do
                    %Decimal{} = s -> add_decimal(inner, s)
                    _ -> inner
                  end
                end)
              end) %>
            <div class="collapse collapse-arrow bg-base-100 shadow border border-base-200">
              <input type="checkbox" checked />
              <div class="collapse-title min-h-0 py-2 font-semibold text-base-content/80 flex items-center gap-2 bg-base-200/50">
                <.icon name="hero-rectangle-stack" class="w-4 h-4 text-base-content/50" />
                <span class="flex-1 truncate">{catalogue_name}</span>
                <span class="w-16 text-center text-xs font-medium uppercase tracking-wide text-base-content/50">
                  {dgettext("default", "Total")}
                </span>
                <span class="w-28 text-right tabular-nums">
                  {format_quantity(catalogue_stock_total)}
                </span>
                <span class="w-28 text-center tabular-nums">
                  {format_quantity(catalogue_qty_total)}
                </span>
                <%= if @track_value do %>
                  <span class="w-28"></span>
                  <span class="w-28 text-right tabular-nums">
                    <.currency_compact amount={catalogue_sum_total} currency="EUR" />
                  </span>
                <% end %>
                <span class="w-10"></span>
              </div>
              <div class="collapse-content px-0 pt-1 pb-0">
                <%= for {category_uuid, category_lines} <- catalogue_groups do %>
                  <% category_name = resolve_name(@names, category_uuid, nil) %>
                  <div class="mb-3 px-2">
                    <div
                      :if={category_name}
                      class="text-sm font-semibold text-base-content/80 py-1 pl-2 mb-1"
                    >
                      {category_name}
                    </div>
                    <div class="overflow-x-auto">
                      <table class="table table-sm w-full">
                        <thead>
                          <tr>
                            <th>{dgettext("default", "Item")}</th>
                            <th class="w-16 text-center">{dgettext("default", "Unit")}</th>
                            <th class="w-28 text-right">{dgettext("default", "Current stock")}</th>
                            <th class="w-28 text-center">{dgettext("default", "Counted")}</th>
                            <%= if @track_value do %>
                              <th class="w-28 text-right">{dgettext("default", "Unit price")}</th>
                              <th class="w-28 text-right">{dgettext("default", "Sum")}</th>
                            <% end %>
                            <th class="w-10"></th>
                          </tr>
                        </thead>
                        <tbody>
                          <%= for {index, line} <- category_lines do %>
                            <% item_uuid = line["item_uuid"] %>
                            <% item_name = resolve_name(@names, item_uuid, line["name"]) %>
                            <% stock_entry = Map.get(@stock_map, item_uuid) %>
                            <% current_qty = stock_entry && stock_entry.quantity %>
                            <% counted = line["counted_quantity"] %>
                            <% unit_value = line["unit_value"] %>
                            <tr class="hover">
                              <td>
                                <div class="font-medium">{item_name}</div>
                                <div class="text-xs text-base-content/40 font-mono">
                                  {line["sku"]}
                                </div>
                              </td>
                              <td class="text-center text-xs text-base-content/60">
                                {unit_label(line["unit"])}
                              </td>
                              <td class="text-right text-sm text-base-content/60">
                                <span class="tabular-nums">{format_quantity(current_qty)}</span>
                              </td>
                              <td class="text-center">
                                <%= if @editable do %>
                                  <form phx-change="set_counted" phx-submit="set_counted">
                                    <input type="hidden" name="index" value={index} />
                                    <input
                                      type="number"
                                      id={"counted-input-#{index}"}
                                      name="counted_quantity"
                                      min="0"
                                      step="any"
                                      value={format_input_decimal(counted)}
                                      placeholder="0"
                                      class="input input-sm w-24 text-center"
                                      phx-debounce="blur"
                                      phx-hook="InvEnterBlur"
                                    />
                                  </form>
                                <% else %>
                                  <span class="tabular-nums text-sm">{format_quantity(counted)}</span>
                                <% end %>
                              </td>
                              <%= if @track_value do %>
                                <td class="text-right">
                                  <%= if @editable do %>
                                    <form phx-change="set_price" phx-submit="set_price">
                                      <input type="hidden" name="index" value={index} />
                                      <input
                                        type="text"
                                        id={"price-input-#{index}"}
                                        name="unit_value"
                                        value={format_input_decimal(unit_value)}
                                        placeholder="—"
                                        class="input input-sm w-24 text-right"
                                        phx-debounce="blur"
                                        phx-hook="InvEnterBlur"
                                      />
                                    </form>
                                  <% else %>
                                    <span class="tabular-nums text-sm">{format_input_decimal(
                                      unit_value
                                    ) || "—"}</span>
                                  <% end %>
                                </td>
                                <td class="text-right">
                                  <%= if @editable do %>
                                    <form phx-change="set_sum" phx-submit="set_sum">
                                      <input type="hidden" name="index" value={index} />
                                      <input
                                        type="text"
                                        id={"sum-input-#{index}"}
                                        name="sum"
                                        value={format_input_decimal(line_sum(counted, unit_value))}
                                        placeholder="—"
                                        class="input input-sm w-24 text-right"
                                        phx-debounce="blur"
                                        phx-hook="InvEnterBlur"
                                      />
                                    </form>
                                  <% else %>
                                    <span class="tabular-nums text-sm">{format_input_decimal(
                                      line_sum(counted, unit_value)
                                    ) || "—"}</span>
                                  <% end %>
                                </td>
                              <% end %>
                              <td class="text-center">
                                <%= if @editable do %>
                                  <button
                                    type="button"
                                    phx-click="remove_line"
                                    phx-value-index={index}
                                    class="btn btn-xs btn-square btn-ghost text-error"
                                    aria-label={dgettext("default", "Remove line")}
                                  >
                                    <.icon name="hero-x-mark" class="w-3 h-3" />
                                  </button>
                                <% end %>
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # stock_sheet/1
  # ---------------------------------------------------------------------------

  @doc """
  Read-only stock sheet grouped by catalogue → category.

  Accepts a flat list of `%{item, quantity, unit_value}` maps where `item`
  has `:catalogue` and `:category` preloaded. Groups are rendered as DaisyUI
  collapsible sections (open by default) with a quantity subtotal badge in
  the catalogue header and a per-category `<tfoot>` subtotal row.

  Columns: Item (name + SKU) / Unit / In stock (qty) / Total value.

  Entries may optionally carry a `:below_min?` boolean (§5 — deficit
  tracking, set by `Web.StockLive.build_stock_items/1`) — when true, a small
  warning icon renders next to the item name. Missing/false is the default
  (`Map.get(entry, :below_min?, false)`), so callers that don't track
  deficits can keep passing the plain `%{item, quantity, unit_value}` shape.
  """
  attr(:stock_items, :list, required: true)
  attr(:locale, :string, required: true)

  def stock_sheet(assigns) do
    ~H"""
    <div>
      <%= if @stock_items == [] do %>
        <div class="text-center py-8 text-base-content/50">
          <.icon name="hero-cube" class="w-8 h-8 mx-auto mb-2 opacity-30" />
          <p class="text-sm">{dgettext("default", "No items in stock.")}</p>
        </div>
      <% else %>
        <% grouped = group_stock_items(@stock_items) %>
        <div class="flex flex-col gap-2">
          <%= for {catalogue, catalogue_groups} <- grouped do %>
            <% catalogue_qty_total =
              Enum.reduce(catalogue_groups, Decimal.new(0), fn {_cat, items}, acc ->
                Enum.reduce(items, acc, fn entry, inner ->
                  add_decimal(inner, entry.quantity)
                end)
              end) %>
            <% catalogue_value_total =
              Enum.reduce(catalogue_groups, Decimal.new(0), fn {_cat, items}, acc ->
                Enum.reduce(items, acc, fn entry, inner ->
                  case entry.unit_value do
                    nil -> inner
                    uv -> add_decimal(inner, Decimal.mult(entry.quantity, uv))
                  end
                end)
              end) %>
            <div class="collapse collapse-arrow bg-base-100 shadow border border-base-200">
              <input type="checkbox" checked />
              <div class="collapse-title min-h-0 py-2 pr-10 font-semibold text-base-content/80 flex items-center gap-2 bg-base-200/50">
                <.icon name="hero-rectangle-stack" class="w-4 h-4 text-base-content/50" />
                <span class="flex-1 truncate">
                  {if catalogue,
                    do: catalogue_display_name(catalogue, @locale),
                    else: dgettext("default", "Uncategorized")}
                </span>
                <span class="w-16 text-center text-xs font-medium uppercase tracking-wide text-base-content/50">
                  {dgettext("default", "Total")}
                </span>
                <span class="w-28 text-right tabular-nums">
                  {format_quantity(catalogue_qty_total)}
                </span>
                <span class="w-36 text-right tabular-nums">
                  <.currency_compact amount={catalogue_value_total} currency="EUR" />
                </span>
              </div>
              <div class="collapse-content px-0 pt-1 pb-0">
                <%= for {category, category_items} <- catalogue_groups do %>
                  <% category_name =
                    if category,
                      do: localized_name(category, @locale),
                      else: nil %>
                  <div class="mb-3 px-2">
                    <div
                      :if={category_name}
                      class="text-sm font-semibold text-base-content/80 py-1 pl-2 mb-1"
                    >
                      {category_name}
                    </div>
                    <div class="overflow-x-auto">
                      <table class="table table-sm w-full">
                        <thead>
                          <tr>
                            <th>{dgettext("default", "Item")}</th>
                            <th class="w-16 text-center">{dgettext("default", "Unit")}</th>
                            <th class="w-28 text-right">{dgettext("default", "In stock")}</th>
                            <th class="w-36 text-right">{dgettext("default", "Total value")}</th>
                          </tr>
                        </thead>
                        <tbody>
                          <%= for entry <- category_items do %>
                            <tr class="hover">
                              <td>
                                <div class="font-medium flex items-center gap-1">
                                  {localized_name(entry.item, @locale)}
                                  <span
                                    :if={Map.get(entry, :below_min?, false)}
                                    title={dgettext("default", "Below minimum stock")}
                                  >
                                    <.icon
                                      name="hero-exclamation-triangle"
                                      class="w-3.5 h-3.5 text-error shrink-0"
                                    />
                                  </span>
                                </div>
                                <div
                                  :if={entry.item.sku}
                                  class="text-xs text-base-content/40 font-mono"
                                >
                                  {entry.item.sku}
                                </div>
                              </td>
                              <td class="text-center text-xs text-base-content/60">
                                {unit_label(entry.item.unit)}
                              </td>
                              <td class="text-right font-medium tabular-nums">
                                {format_quantity(entry.quantity)}
                              </td>
                              <td class="text-right">
                                <%= if entry.unit_value do %>
                                  <span class="tabular-nums">
                                    <.currency_compact amount={Decimal.mult(entry.quantity, entry.unit_value)} currency="EUR" />
                                  </span>
                                <% else %>
                                  <span class="text-base-content/30">—</span>
                                <% end %>
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # source_picker/1
  # ---------------------------------------------------------------------------

  @doc """
  Stateless modal component for selecting source documents to import into a
  warehouse document.

  ## Attrs

  - `id` — explicit modal id (string, required). Pass a stable per-form id to
    avoid collision when multiple modals share the same page.
  - `show` — controls visibility (boolean, required).
  - `title` — modal header title string (required).
  - `on_close` — phx event name sent on cancel / backdrop click (string, required).
  - `candidates` — list of `%{uuid, label, label_prefix}` maps to display
    (label_prefix is optional). The parent LiveView builds this list from DB queries in
    `handle_event/3` for `"source_picker_search"`.
  - `selected_uuids` — `MapSet` (or list) of already-selected UUIDs; drives
    the checkbox state per row (required).
  - `search_query` — current value of the search input, echoed into the field
    on re-render (default `""`).

  ## Parent events to implement

  The component fires these fixed phx event names; the parent LiveView MUST
  implement `handle_event/3` for each:

  - `"source_picker_search"` — fired on phx-change of the search form.
    Params: `%{"query" => string}`.
    The parent should re-query candidates and assign them.

  - `"source_picker_toggle"` — fired on phx-click of a candidate row.
    Params: `%{"uuid" => binary}`.
    The parent should toggle the UUID in/out of `selected_uuids`.

  - `"source_picker_select_all"` — fired on phx-click of the "Select all"
    toggle. No extra phx-values. The parent should select every UUID
    currently in `candidates` when not all are selected yet, or clear the
    selection when they already all are.

  - `"source_picker_confirm"` — fired on the "Import (N)" primary button.
    No extra phx-values. The parent reads its own `selected_uuids` assign,
    runs the import logic, and then clears the modal.

  The `on_close` event is also a parent-side event (cancel / backdrop close).
  """
  attr(:id, :string, required: true)
  attr(:show, :boolean, required: true)
  attr(:title, :string, required: true)
  attr(:on_close, :string, required: true)
  attr(:candidates, :list, default: [])
  attr(:selected_uuids, :any, default: [])
  attr(:search_query, :string, default: "")

  def source_picker(assigns) do
    assigns =
      assigns
      |> assign(:selected_count, Enum.count(assigns.selected_uuids))
      |> assign(
        :all_selected?,
        assigns.candidates != [] &&
          Enum.all?(assigns.candidates, &Enum.member?(assigns.selected_uuids, &1.uuid))
      )

    ~H"""
    <.modal id={@id} show={@show} on_close={@on_close} max_width="2xl" max_height="80vh">
      <:title>{@title}</:title>

      <%!-- Search form --%>
      <form
        phx-change="source_picker_search"
        phx-submit="source_picker_search"
        class="mb-3 flex gap-2"
      >
        <input
          type="text"
          name="query"
          value={@search_query}
          placeholder={dgettext("default", "Search...")}
          class="input input-sm flex-1"
          phx-debounce="300"
          autocomplete="off"
        />
        <button
          type="button"
          phx-click="source_picker_select_all"
          disabled={@candidates == []}
          class="btn btn-sm btn-outline whitespace-nowrap"
        >
          {if @all_selected?,
            do: dgettext("default", "Deselect all"),
            else: dgettext("default", "Select all")}
        </button>
      </form>

      <%!-- Candidate list --%>
      <%= if @candidates == [] do %>
        <div class="text-center py-8 text-base-content/50">
          <.icon name="hero-document-magnifying-glass" class="w-8 h-8 mx-auto mb-2 opacity-30" />
          <p class="text-sm">{dgettext("default", "No documents found.")}</p>
        </div>
      <% else %>
        <div class="overflow-y-auto max-h-96 flex flex-col gap-0.5">
          <%= for candidate <- @candidates do %>
            <% selected? = Enum.member?(@selected_uuids, candidate.uuid) %>
            <label class={[
              "flex items-center gap-3 px-3 py-2 rounded-lg cursor-pointer transition-colors",
              selected? && "bg-primary/10 border border-primary/30",
              !selected? && "hover:bg-base-200 border border-transparent"
            ]}>
              <input
                type="checkbox"
                class="checkbox checkbox-sm checkbox-primary"
                checked={selected?}
                phx-click="source_picker_toggle"
                phx-value-uuid={candidate.uuid}
              />
              <div class="flex-1 min-w-0">
                <div class="font-medium text-sm">{candidate.label}</div>
              </div>
              <div :if={Map.get(candidate, :label_prefix)} class="flex-shrink-0">
                <span class="badge badge-sm badge-ghost">{candidate.label_prefix}</span>
              </div>
            </label>
          <% end %>
        </div>
      <% end %>

      <:actions>
        <button type="button" phx-click={@on_close} class="btn btn-sm btn-ghost">
          {dgettext("default", "Cancel")}
        </button>
        <button
          type="button"
          phx-click="source_picker_confirm"
          disabled={@selected_count == 0}
          class="btn btn-sm btn-primary"
        >
          {dgettext("default", "Import (%{n})", n: @selected_count)}
        </button>
      </:actions>
    </.modal>
    """
  end

  # ---------------------------------------------------------------------------
  # Public helpers (ported from Andi.Catalogues)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the display name of a catalogue / category / item record in the
  given UI locale, reading translations from the multilang `data` JSONB via
  `PhoenixKitCatalogue.Catalogue.get_translation/2`. Falls back to the
  embedded primary translation, then to the denormalized `name` column.
  Returns `nil` for `nil` records.

  Ported from `Andi.Catalogues.localized_name/2` — that function does not
  exist on `PhoenixKitCatalogue.Catalogue` itself (confirmed, matching
  Plan 3's identical finding for `Inventories`), so this is real ported
  logic, not a call-through. Unlike the original, `locale` is used exactly
  as given — the original's `Andi.Locales.entity_locale/1`/`current_locale/0`
  normalization is Andi-specific and dropped; callers pass an
  already-resolved locale string (see this plan's Global Constraints on
  `Andi.Locales.sync_from_phoenix_kit/0`).
  """
  @spec localized_name(map() | struct() | nil, String.t() | nil) :: String.t() | nil
  def localized_name(nil, _locale), do: nil

  def localized_name(record, locale) do
    translation = safe_get_translation(record, locale)
    pick_name(translation) || Map.get(record, :name)
  end

  defp safe_get_translation(record, locale) do
    Catalogue.get_translation(record, locale)
  rescue
    _ -> %{}
  end

  defp pick_name(translation) when is_map(translation) do
    case Map.get(translation, "_name") || Map.get(translation, "name") do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp pick_name(_), do: nil

  @doc """
  Short localized label for a catalogue item unit of measure. Ported from
  `Andi.Catalogues.unit_label/1` verbatim.
  """
  @spec unit_label(String.t() | nil) :: String.t()
  def unit_label(nil), do: ""
  def unit_label("piece"), do: dgettext("default", "pc")
  def unit_label("set"), do: dgettext("default", "set")
  def unit_label("pair"), do: dgettext("default", "pair")
  def unit_label("sheet"), do: dgettext("default", "sheet")
  def unit_label("m2"), do: dgettext("default", "m²")
  def unit_label("running_meter"), do: dgettext("default", "rm")
  def unit_label(other), do: other

  @doc """
  Strips a configurable catalogue-name prefix (case-insensitive), along with
  any single separating space. Returns the original name if the prefix isn't
  present, or if stripping would yield an empty string.

  Ported from `Andi.Catalogues.strip_prefix/1`. The original reads
  `Application.get_env(:andi, :catalogue_prefix, "ANDI")` — Andi-specific
  config the package cannot reference. This reads
  `Application.get_env(:phoenix_kit_warehouse, :catalogue_prefix, "")`
  instead, defaulting to an **empty string** (no-op — every catalogue name
  passes through unchanged) rather than a hardcoded brand string, so the
  package behaves sensibly out of the box for a fresh host with no
  catalogue-naming convention at all. A host that does use a shared naming
  prefix opts in via config.
  """
  @spec strip_prefix(String.t() | nil) :: String.t() | nil
  def strip_prefix(nil), do: nil

  def strip_prefix(name) when is_binary(name) do
    prefix = Application.get_env(:phoenix_kit_warehouse, :catalogue_prefix, "")
    plen = String.length(prefix)

    if plen > 0 and String.downcase(String.slice(name, 0, plen)) == String.downcase(prefix) do
      rest = name |> String.slice(plen, String.length(name)) |> String.trim_leading()
      if rest == "", do: name, else: rest
    else
      name
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Groups lines by catalogue_uuid then category_uuid, preserving original
  # index so events reference the right line.
  defp group_lines(lines) do
    lines
    |> Enum.with_index()
    |> Enum.group_by(fn {line, _i} -> line["catalogue_uuid"] end)
    |> Enum.map(fn {cat_uuid, cat_lines} ->
      by_category =
        cat_lines
        |> Enum.group_by(fn {line, _i} -> line["category_uuid"] end)
        |> Enum.map(fn {cat_key, pairs} ->
          {cat_key, Enum.map(pairs, fn {line, i} -> {i, line} end)}
        end)

      {cat_uuid, by_category}
    end)
  end

  defp resolve_name(names, uuid, fallback) do
    Map.get(names, uuid) || fallback
  end

  defp catalogue_display_name(catalogue, locale) do
    catalogue |> localized_name(locale) |> strip_prefix()
  end

  defp open_class(true), do: "collapse-open"
  defp open_class(false), do: "collapse-close"

  defp format_quantity(nil), do: "0"
  defp format_quantity(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_quantity(n) when is_integer(n), do: Integer.to_string(n)
  defp format_quantity(s) when is_binary(s), do: s

  defp format_input_decimal(nil), do: ""
  defp format_input_decimal(""), do: ""
  defp format_input_decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_input_decimal(n) when is_integer(n), do: Integer.to_string(n)
  defp format_input_decimal(n) when is_float(n), do: Float.to_string(n)
  defp format_input_decimal(s) when is_binary(s), do: s

  defp line_sum(counted, unit_value) do
    with %Decimal{} <- safe_decimal(counted),
         %Decimal{} <- safe_decimal(unit_value) do
      Decimal.mult(safe_decimal(counted), safe_decimal(unit_value))
      |> Decimal.round(2)
    else
      _ -> nil
    end
  end

  defp safe_decimal(nil), do: nil
  defp safe_decimal(""), do: nil
  defp safe_decimal(%Decimal{} = d), do: d

  defp safe_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp safe_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp safe_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp safe_decimal(_), do: nil

  # Groups a flat list of %{item, quantity, unit_value} by item.catalogue then
  # item.category. Both are preloaded structs (or nil for uncategorized items).
  # Returns [{catalogue | nil, [{category | nil, [entry]}]}]
  defp group_stock_items(items) do
    items
    |> Enum.group_by(fn %{item: item} -> item.catalogue end)
    |> Enum.sort_by(fn {catalogue, _} ->
      String.downcase((catalogue && catalogue.name) || "")
    end)
    |> Enum.map(fn {catalogue, catalogue_items} ->
      by_category =
        catalogue_items
        |> Enum.group_by(fn %{item: item} -> item.category end)
        |> Enum.sort_by(fn {category, _} ->
          String.downcase((category && category.name) || "")
        end)

      {catalogue, by_category}
    end)
  end

  # Adds two Decimal values; treats nil as zero.
  defp add_decimal(acc, nil), do: acc
  defp add_decimal(acc, %Decimal{} = d), do: Decimal.add(acc, d)
end
