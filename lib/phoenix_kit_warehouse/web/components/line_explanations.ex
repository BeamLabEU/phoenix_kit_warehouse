defmodule PhoenixKitWarehouse.Web.Components.LineExplanations do
  @moduledoc """
  Collapsible "Why" block under the lines table of the internal-order and
  supplier-order forms.

  Lists each line that carries an `"explanation"` (see
  `PhoenixKitWarehouse.LineExplanation`) next to the item name. Opt-in: it
  renders nothing unless at least one line has an explanation, so a host that
  never supplies one sees no change. With `quantity_logic?` it also explains
  how a supplier-order quantity is derived.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  alias PhoenixKitWarehouse.LineExplanation

  attr(:id, :string, required: true)
  attr(:lines, :list, required: true)
  attr(:names, :map, default: %{})
  attr(:quantity_logic?, :boolean, default: false)

  def explanations(assigns) do
    assigns = assign(assigns, :entries, entries(assigns.lines, assigns.names))

    ~H"""
    <details :if={@entries != []} id={@id} class="collapse collapse-arrow bg-base-200 mt-4">
      <summary class="collapse-title text-sm font-medium">
        {dgettext("default", "Why")}
      </summary>
      <div class="collapse-content space-y-3 text-sm">
        <p :if={@quantity_logic?} id={"#{@id}-quantity-logic"} class="text-base-content/70">
          {dgettext(
            "default",
            "The order is the requirement of the internal order minus the stock on hand at the warehouse location at the moment of generation. On import, the quantity already ordered in other supplier orders is subtracted as well. The supplier is the one found for the item: the primary supplier or one through the manufacturer. Items without a single supplier do not get into this order. If the quantity in the order was edited by hand, it may differ from the calculation."
          )}
        </p>
        <div :for={{name, text} <- @entries} class="space-y-1">
          <div class="font-medium">{name}</div>
          <div class="whitespace-pre-line text-base-content/70">{text}</div>
        </div>
      </div>
    </details>
    """
  end

  defp entries(lines, names) do
    for line <- lines, text = LineExplanation.get(line) do
      {Map.get(names, line["item_uuid"]) || line["name"] || "—", text}
    end
  end
end
