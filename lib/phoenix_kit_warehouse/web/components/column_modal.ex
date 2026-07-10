defmodule PhoenixKitWarehouse.Web.Components.ColumnModal do
  @moduledoc """
  Function component for the "Customize columns" modal used by Andi list LVs.

  Layout: two columns inside the modal.

    * Selected (left) — drag to reorder. Each row also exposes a filter toggle
      for filterable columns; toggled state persists alongside column order.
    * Available (right) — click to add.

  The host LiveView must implement these `handle_event/3` callbacks (provided
  by `PhoenixKitWarehouse.Web.ColumnManagement`):

    * `"hide_column_modal"`
    * `"add_column"` (`%{"column_id" => id}`)
    * `"remove_column"` (`%{"column_id" => id}`)
    * `"toggle_filter"` (`%{"column_id" => id}`)
    * `"reorder_selected_columns"` (`%{"ordered_ids" => [...]}`)
    * `"update_table_columns"` (form submit, `%{"column_order" => csv}`)
    * `"reset_to_defaults"`
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitWeb.Components.Core.DraggableList

  attr(:id, :string, default: "warehouse-column-modal")
  attr(:show, :boolean, required: true)
  attr(:column_config, :atom, required: true)
  attr(:selected, :list, required: true)
  attr(:active_filters, :list, default: [])
  attr(:temp_selected, :list, default: nil)
  attr(:temp_active_filters, :list, default: nil)

  def column_modal(assigns) do
    column_meta = assigns.column_config.column_metadata_map()
    available = assigns.column_config.available_columns()
    current = assigns.temp_selected || assigns.selected
    current_filters = assigns.temp_active_filters || assigns.active_filters

    assigns =
      assigns
      |> assign(:column_meta, column_meta)
      |> assign(:available, available)
      |> assign(:current, current)
      |> assign(:current_filters, current_filters)

    ~H"""
    <div :if={@show} class="modal modal-open" id={@id}>
      <div class="modal-box max-w-5xl max-h-[90vh] overflow-hidden">
        <h3 class="font-bold text-xl mb-4">{dgettext("default", "Customize columns")}</h3>
        <p class="text-base-content/70 mb-6">
          {dgettext(
            "default",
            "Drag selected columns to reorder, click an available column to add it. Toggle the funnel icon on a column to enable per-column filtering."
          )}
        </p>

        <form phx-submit="update_table_columns" id={"#{@id}-form"}>
          <input type="hidden" name="column_order" value={Enum.join(@current, ",")} />

          <div class="flex flex-col lg:flex-row gap-6 mb-6">
            <div class="flex-1">
              <div class="flex items-center justify-between mb-3">
                <h4 class="text-sm font-semibold uppercase tracking-wide">
                  {dgettext("default", "Selected")}
                </h4>
                <span class="text-xs text-base-content/60">
                  {dgettext("default", "Drag to reorder")}
                </span>
              </div>

              <DraggableList.draggable_list
                id={"#{@id}-selected"}
                items={@current}
                item_id={fn id -> id end}
                on_reorder="reorder_selected_columns"
                layout={:list}
                gap="space-y-2"
                class="min-h-[200px] max-h-[400px] overflow-y-auto border-2 border-dashed border-base-300 rounded-lg p-3"
                item_class="flex items-center p-3 rounded-lg bg-primary/10 border border-primary/30 hover:bg-primary/20"
              >
                <:item :let={column_id}>
                  <% meta = Map.get(@column_meta, column_id) %>
                  <div class="text-primary/60 mr-3 cursor-grab">
                    <.icon name="hero-bars-3" class="h-5 w-5" />
                  </div>
                  <span class="flex-1 font-medium">
                    {(meta && meta.label.()) || column_id}
                  </span>

                  <button
                    :if={meta && Map.get(meta, :filterable?, false)}
                    type="button"
                    class={[
                      "btn btn-ghost btn-xs btn-circle mr-1",
                      column_id in @current_filters && "text-primary",
                      column_id not in @current_filters && "text-base-content/40 hover:text-primary"
                    ]}
                    phx-click="toggle_filter"
                    phx-value-column_id={column_id}
                    title={
                      if column_id in @current_filters,
                        do: dgettext("default", "Disable filter"),
                        else: dgettext("default", "Enable filter")
                    }
                  >
                    <.icon name="hero-funnel" class="h-4 w-4" />
                  </button>

                  <button
                    type="button"
                    class="btn btn-ghost btn-xs btn-circle text-error/60 hover:text-error"
                    phx-click="remove_column"
                    phx-value-column_id={column_id}
                    title={dgettext("default", "Remove")}
                  >
                    <.icon name="hero-x-mark" class="h-4 w-4" />
                  </button>
                </:item>
              </DraggableList.draggable_list>

              <div
                :if={@current == []}
                class="text-center py-12 text-base-content/40 border-2 border-dashed rounded-lg mt-2"
              >
                <.icon name="hero-clipboard-document-list" class="h-12 w-12 mx-auto mb-3" />
                <p class="text-sm">{dgettext("default", "No columns selected")}</p>
              </div>
            </div>

            <div class="flex-1">
              <div class="flex items-center justify-between mb-3">
                <h4 class="text-sm font-semibold uppercase tracking-wide">
                  {dgettext("default", "Available")}
                </h4>
                <span class="text-xs text-base-content/60">
                  {dgettext("default", "Click to add")}
                </span>
              </div>

              <div class="max-h-[400px] overflow-y-auto border border-base-200 rounded-lg p-3">
                <% remaining = Enum.reject(@available, &(&1.id in @current)) %>
                <div :if={remaining != []} class="space-y-1">
                  <button
                    :for={meta <- remaining}
                    type="button"
                    class="w-full flex items-center p-2 rounded-lg hover:bg-base-200 text-left border border-transparent hover:border-base-300"
                    phx-click="add_column"
                    phx-value-column_id={meta.id}
                  >
                    <span class="flex-1 font-medium text-sm">{meta.label.()}</span>
                    <.icon
                      :if={Map.get(meta, :filterable?, false)}
                      name="hero-funnel"
                      class="h-4 w-4 text-base-content/30 mr-2"
                    />
                    <.icon name="hero-plus" class="h-4 w-4 text-success/60" />
                  </button>
                </div>

                <div :if={remaining == []} class="text-center py-8 text-base-content/40">
                  <p class="text-sm">{dgettext("default", "All columns selected")}</p>
                </div>
              </div>
            </div>
          </div>

          <div class="modal-action">
            <button type="submit" class="btn btn-primary">
              {dgettext("default", "Apply")}
            </button>
            <button type="button" class="btn btn-outline" phx-click="reset_to_defaults">
              {dgettext("default", "Defaults")}
            </button>
            <button type="button" class="btn btn-ghost" phx-click="hide_column_modal">
              {dgettext("default", "Cancel")}
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="hide_column_modal"></div>
    </div>
    """
  end
end
