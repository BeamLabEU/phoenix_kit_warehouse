defmodule PhoenixKitWarehouse.Web.Components.FilterChips do
  @moduledoc """
  Inline filter input components rendered in a list LiveView's toolbar, one
  per active filter. Each chip:

    * sends `set_filter_value` (`%{"column_id" => id, "value" => value}`) on
      change, debounced for `:text`;
    * sends `clear_filter` (`%{"column_id" => id}`) when the ✕ button is hit;
    * renders a per-`filter_type` input (`:text` / `:enum` / `:numeric_range` /
      `:date_range`).

  All chips are rendered inside their own `<form phx-change="set_filter_value">`
  with a hidden `column_id` input so the host LiveView's `handle_event` always
  receives both the id and the value.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr(:meta, :map, required: true, doc: "Column metadata from ColumnConfig")
  attr(:value, :any, default: nil, doc: "Current filter value (any shape)")
  attr(:entries, :list, default: [], doc: "Visible entries — for dynamic enum options")

  def filter_chip(assigns) do
    ~H"""
    <div class="flex items-center gap-1 bg-base-200 rounded-md px-2 py-1">
      <.icon name="hero-funnel" class="h-3.5 w-3.5 text-base-content/60" />
      <span class="text-xs text-base-content/70 font-medium whitespace-nowrap">
        {@meta.label.()}:
      </span>

      <form phx-change="set_filter_value" class="flex items-center gap-1">
        <input type="hidden" name="column_id" value={@meta.id} />
        <.input_for_type meta={@meta} value={@value} entries={@entries} />
      </form>

      <button
        type="button"
        class="btn btn-ghost btn-xs btn-circle text-base-content/50 hover:text-error"
        phx-click="clear_filter"
        phx-value-column_id={@meta.id}
        title={dgettext("default", "Clear filter")}
      >
        <.icon name="hero-x-mark" class="h-3.5 w-3.5" />
      </button>
    </div>
    """
  end

  attr(:meta, :map, required: true)
  attr(:value, :any, default: nil)
  attr(:entries, :list, default: [])

  defp input_for_type(%{meta: %{filter_type: :text}} = assigns) do
    ~H"""
    <input
      type="search"
      name="value"
      value={@value || ""}
      placeholder={dgettext("default", "Contains...")}
      class="input input-xs input-bordered w-32"
      phx-debounce="300"
    />
    """
  end

  defp input_for_type(%{meta: %{filter_type: :enum}} = assigns) do
    options =
      case Map.get(assigns.meta, :filter_options) do
        fun when is_function(fun, 1) -> fun.(assigns.entries)
        _ -> []
      end

    assigns = assign(assigns, :options, options)

    ~H"""
    <select name="value" class="select select-xs select-bordered">
      <option value="" selected={@value in [nil, ""]}>
        {dgettext("default", "Any")}
      </option>
      <%= for {val, label} <- @options do %>
        <option value={val} selected={to_string(@value) == to_string(val)}>{label}</option>
      <% end %>
    </select>
    """
  end

  defp input_for_type(%{meta: %{filter_type: :numeric_range}} = assigns) do
    {min, max} = split_range(assigns.value)
    assigns = assigns |> assign(:min, min) |> assign(:max, max)

    ~H"""
    <input
      type="number"
      step="any"
      name="value[min]"
      value={@min}
      placeholder={dgettext("default", "Min")}
      class="input input-xs input-bordered w-20"
      phx-debounce="300"
    />
    <span class="text-xs text-base-content/40">–</span>
    <input
      type="number"
      step="any"
      name="value[max]"
      value={@max}
      placeholder={dgettext("default", "Max")}
      class="input input-xs input-bordered w-20"
      phx-debounce="300"
    />
    """
  end

  defp input_for_type(%{meta: %{filter_type: :date_range}} = assigns) do
    {from, to} = split_date_range(assigns.value)
    assigns = assigns |> assign(:from, from) |> assign(:to, to)

    ~H"""
    <input
      type="date"
      name="value[from]"
      value={@from}
      class="input input-xs input-bordered w-36"
    />
    <span class="text-xs text-base-content/40">–</span>
    <input
      type="date"
      name="value[to]"
      value={@to}
      class="input input-xs input-bordered w-36"
    />
    """
  end

  defp input_for_type(assigns) do
    ~H"""
    <span class="text-xs text-base-content/50">
      {dgettext("default", "Unsupported filter type")}
    </span>
    """
  end

  defp split_range(%{"min" => min, "max" => max}), do: {min || "", max || ""}
  defp split_range(_), do: {"", ""}

  defp split_date_range(%{"from" => from, "to" => to}), do: {from || "", to || ""}
  defp split_date_range(_), do: {"", ""}
end
