defmodule PhoenixKitWarehouse.Web.ColumnManagement do
  @moduledoc """
  `use`-macro that injects column-management `handle_event/3` callbacks into a
  LiveView. Generic across scopes — pass the column-config module and scope via
  options:

      use PhoenixKitWarehouse.Web.ColumnManagement,
        column_config: PhoenixKitWarehouse.ColumnConfig.InternalOrders,
        scope: "warehouse_internal_orders"

  ## Required socket assigns (set them in `mount/3`)

    * `:current_user_uuid` — used for persistence keying.
    * `:selected_columns` — initial list of visible column ids.
    * `:active_filters` — initial list of column ids with active filter inputs.
    * `:filter_values` — initial `%{column_id => value}` map (session-local).
    * `:show_column_modal` — `false`.
    * `:temp_selected_columns` / `:temp_active_filters` — `nil`.

  Use `assign_column_state/2` to bootstrap all of the above from the persisted
  config.

  ## View refresh

  Filter changes (`set_filter_value`, `clear_filter`, save) need to recompute
  the visible list. The macro calls `__view_config_changed__/1` after mutating
  state. The default implementation is identity; the host LV overrides it:

      defoverridable __view_config_changed__: 1
      def __view_config_changed__(socket) do
        # rebuild socket.assigns.entries from source + selected/filters/sort
      end

  ## Persisted shape (`view_config`)

      %{
        "columns" => ["id", ...],
        "active_filters" => ["id", ...]
      }

  Filter values are intentionally NOT persisted — they reset between sessions
  to avoid the "ghost filter" UX (user opens the page next week and finds zero
  results because of a saved filter they forgot about).
  """

  use Gettext, backend: PhoenixKitWarehouse.Gettext

  defmacro __using__(opts) do
    column_config = Keyword.fetch!(opts, :column_config)
    scope = Keyword.fetch!(opts, :scope)

    quote do
      @column_config unquote(column_config)
      @column_config_scope unquote(scope)

      import PhoenixKitWarehouse.Web.ColumnManagement, only: [assign_column_state: 2]

      def __view_config_changed__(socket), do: socket
      defoverridable __view_config_changed__: 1

      @impl true
      def handle_event("show_column_modal", _params, socket) do
        {:noreply,
         socket
         |> Phoenix.Component.assign(:show_column_modal, true)
         |> Phoenix.Component.assign(:temp_selected_columns, socket.assigns.selected_columns)
         |> Phoenix.Component.assign(:temp_active_filters, socket.assigns.active_filters)}
      end

      def handle_event("hide_column_modal", _params, socket) do
        {:noreply,
         socket
         |> Phoenix.Component.assign(:show_column_modal, false)
         |> Phoenix.Component.assign(:temp_selected_columns, nil)
         |> Phoenix.Component.assign(:temp_active_filters, nil)}
      end

      def handle_event("add_column", %{"column_id" => id}, socket) do
        valid = @column_config.all_column_ids()
        temp = socket.assigns.temp_selected_columns || socket.assigns.selected_columns

        new_temp =
          cond do
            id not in valid -> temp
            id in temp -> temp
            true -> temp ++ [id]
          end

        {:noreply, Phoenix.Component.assign(socket, :temp_selected_columns, new_temp)}
      end

      def handle_event("remove_column", %{"column_id" => id}, socket) do
        temp = socket.assigns.temp_selected_columns || socket.assigns.selected_columns
        temp_filters = socket.assigns.temp_active_filters || socket.assigns.active_filters

        {:noreply,
         socket
         |> Phoenix.Component.assign(:temp_selected_columns, Enum.reject(temp, &(&1 == id)))
         |> Phoenix.Component.assign(:temp_active_filters, Enum.reject(temp_filters, &(&1 == id)))}
      end

      def handle_event("toggle_filter", %{"column_id" => id}, socket) do
        meta_map = @column_config.column_metadata_map()
        meta = Map.get(meta_map, id)
        selected = socket.assigns.temp_selected_columns || socket.assigns.selected_columns
        filters = socket.assigns.temp_active_filters || socket.assigns.active_filters

        cond do
          is_nil(meta) or not Map.get(meta, :filterable?, false) ->
            {:noreply, socket}

          id not in selected ->
            {:noreply, socket}

          id in filters ->
            {:noreply,
             Phoenix.Component.assign(
               socket,
               :temp_active_filters,
               Enum.reject(filters, &(&1 == id))
             )}

          true ->
            {:noreply, Phoenix.Component.assign(socket, :temp_active_filters, filters ++ [id])}
        end
      end

      def handle_event("reorder_selected_columns", params, socket) do
        new_order =
          case params do
            %{"ordered_ids" => order} when is_list(order) -> order
            %{"order" => order} when is_list(order) -> order
            %{"column_order" => csv} when is_binary(csv) -> String.split(csv, ",", trim: true)
            _ -> []
          end

        if new_order == [] do
          {:noreply, socket}
        else
          temp = socket.assigns.temp_selected_columns || socket.assigns.selected_columns
          valid = Enum.filter(new_order, &(&1 in temp))
          {:noreply, Phoenix.Component.assign(socket, :temp_selected_columns, valid)}
        end
      end

      def handle_event("reset_to_defaults", _params, socket) do
        defaults = @column_config.default_columns()

        {:noreply,
         socket
         |> Phoenix.Component.assign(:temp_selected_columns, defaults)
         |> Phoenix.Component.assign(:temp_active_filters, [])}
      end

      def handle_event("update_table_columns", params, socket) do
        ordered =
          case params do
            %{"column_order" => csv} when is_binary(csv) ->
              String.split(csv, ",", trim: true)

            _ ->
              socket.assigns.temp_selected_columns || socket.assigns.selected_columns
          end

        active_filters = socket.assigns.temp_active_filters || socket.assigns.active_filters

        PhoenixKitWarehouse.Web.ColumnManagement.save_view_config(
          socket,
          ordered,
          active_filters,
          @column_config,
          @column_config_scope,
          __MODULE__
        )
      end

      def handle_event("set_filter_value", %{"column_id" => id} = params, socket) do
        if id in socket.assigns.active_filters do
          value = Map.get(params, "value", Map.delete(params, "column_id"))
          new_values = Map.put(socket.assigns.filter_values, id, value)

          {:noreply,
           socket
           |> Phoenix.Component.assign(:filter_values, new_values)
           |> __view_config_changed__()}
        else
          {:noreply, socket}
        end
      end

      def handle_event("clear_filter", %{"column_id" => id}, socket) do
        {:noreply,
         socket
         |> Phoenix.Component.assign(:filter_values, Map.delete(socket.assigns.filter_values, id))
         |> __view_config_changed__()}
      end
    end
  end

  @doc """
  Persist the selected columns + active filters for the current user and apply
  them to the socket. Kept here (rather than in the `__using__` quote) so the
  macro stays thin; `view_module.__view_config_changed__/1` lets each using
  LiveView hook in after a successful save.
  """
  def save_view_config(socket, columns, active_filters, column_config, scope, view_module) do
    valid_cols = column_config.validate_columns(columns)
    # Filters can only be active for currently selected columns.
    valid_filters =
      column_config.validate_filters(active_filters)
      |> Enum.filter(&(&1 in valid_cols))

    config = %{"columns" => valid_cols, "active_filters" => valid_filters}
    user_uuid = socket.assigns.current_user_uuid

    save_result =
      if is_binary(user_uuid) do
        PhoenixKitWarehouse.ViewConfigs.merge_view_config(user_uuid, scope, config)
      else
        {:ok, :no_persistence}
      end

    case save_result do
      {:ok, _} ->
        # Drop filter values for columns whose filter is no longer active.
        kept_values = Map.take(socket.assigns.filter_values, valid_filters)

        socket =
          socket
          |> Phoenix.Component.assign(:selected_columns, valid_cols)
          |> Phoenix.Component.assign(:active_filters, valid_filters)
          |> Phoenix.Component.assign(:filter_values, kept_values)
          |> Phoenix.Component.assign(:show_column_modal, false)
          |> Phoenix.Component.assign(:temp_selected_columns, nil)
          |> Phoenix.Component.assign(:temp_active_filters, nil)
          |> Phoenix.LiveView.put_flash(
            :info,
            dgettext("default", "Columns updated")
          )

        {:noreply, view_module.__view_config_changed__(socket)}

      {:error, _} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           dgettext("default", "Failed to save columns")
         )}
    end
  end

  @doc """
  Bootstrap all column-management assigns from the persisted config. Pass the
  column-config module so this helper stays scope-agnostic.
  """
  @spec assign_column_state(Phoenix.LiveView.Socket.t(), module()) ::
          Phoenix.LiveView.Socket.t()
  def assign_column_state(socket, column_config_module) do
    user_uuid = socket.assigns.current_user_uuid
    scope = column_config_module.scope()

    config =
      if is_binary(user_uuid),
        do: PhoenixKitWarehouse.ViewConfigs.get_view_config(user_uuid, scope),
        else: %{}

    selected =
      case Map.get(config, "columns") do
        cols when is_list(cols) and cols != [] -> column_config_module.validate_columns(cols)
        _ -> column_config_module.default_columns()
      end

    active_filters =
      case Map.get(config, "active_filters") do
        ids when is_list(ids) ->
          column_config_module.validate_filters(ids) |> Enum.filter(&(&1 in selected))

        _ ->
          []
      end

    socket
    |> Phoenix.Component.assign(:selected_columns, selected)
    |> Phoenix.Component.assign(:active_filters, active_filters)
    |> Phoenix.Component.assign(:filter_values, %{})
    |> Phoenix.Component.assign(:show_column_modal, false)
    |> Phoenix.Component.assign(:temp_selected_columns, nil)
    |> Phoenix.Component.assign(:temp_active_filters, nil)
  end
end
