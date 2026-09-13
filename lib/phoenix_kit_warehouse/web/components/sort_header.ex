defmodule PhoenixKitWarehouse.Web.Components.SortHeader do
  @moduledoc """
  The clickable column header every warehouse list table uses.

  Renders the column label with a sort chevron and raises `"toggle_sort"`
  (with `phx-value-by`) on the parent LiveView, so it needs no `phx-target`
  and works in every list view that implements that event. It lived as an
  identical private component in each of the seven list LiveViews; keeping
  one copy means a layout fix lands everywhere at once.
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr(:by, :string, required: true)
  attr(:label, :string, required: true)
  attr(:sort_by, :string, required: true)
  attr(:sort_dir, :atom, required: true)
  attr(:align, :atom, default: :left)

  def sort_header(assigns) do
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
      <%!--
        The chevron is always in the layout and only its VISIBILITY flips.
        Rendering it with `:if` made the header cell 14px narrower/shorter on
        every column but the sorted one, so picking a sort visibly resized the
        header row — and with it the whole table's first row. `invisible` keeps
        the box, so sorting changes what the header says, never how big it is.
      --%>
      <.icon
        name={if @sort_dir == :asc, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini"}
        class={"w-3.5 h-3.5 shrink-0" <> if(@active?, do: "", else: " invisible")}
      />
    </button>
    """
  end
end
