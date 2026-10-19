defmodule PhoenixKitWarehouse.Web.Components.TrashTabs do
  @moduledoc """
  The "Active / Trash (N)" tabs of the internal and supplier order lists.

  The Trash tab shows while the trash holds something (`trash_count > 0`) or
  while the list is showing it, so the way back is never hidden. A click sends
  `set_view` with the tab (`"active"` or `"trash"`) in `phx-value-view`; the
  LiveView keeps the choice in the URL (`?view=trash`).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  attr(:prefix, :string, required: true, doc: "DOM id prefix, e.g. \"io\"")
  attr(:view, :string, required: true, doc: "\"active\" or \"trash\"")
  attr(:trash_count, :integer, required: true)

  def trash_tabs(assigns) do
    ~H"""
    <div id={"#{@prefix}-view-tabs"} role="tablist" class="tabs tabs-border">
      <button
        type="button"
        role="tab"
        aria-selected={to_string(@view == "active")}
        id={"#{@prefix}-tab-active"}
        phx-click="set_view"
        phx-value-view="active"
        class={["tab", @view == "active" && "tab-active"]}
      >
        {dgettext("default", "Active")}
      </button>
      <button
        :if={@trash_count > 0 or @view == "trash"}
        type="button"
        role="tab"
        aria-selected={to_string(@view == "trash")}
        id={"#{@prefix}-tab-trash"}
        phx-click="set_view"
        phx-value-view="trash"
        class={["tab", @view == "trash" && "tab-active"]}
      >
        {dgettext("default", "Trash (%{count})", count: @trash_count)}
      </button>
    </div>
    """
  end
end
