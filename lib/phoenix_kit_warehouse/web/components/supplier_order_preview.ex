defmodule PhoenixKitWarehouse.Web.Components.SupplierOrderPreview do
  @moduledoc """
  The window of "Generate supplier orders" on a posted internal order: what
  the generation will write, drawn from `SupplierOrders.assemble/2` of the
  plan and the person's choices (`PhoenixKitWarehouse.Web.SupplierOrderPreview`).

  Three blocks in one form (`phx-change="preview_change"`,
  `phx-submit="preview_confirm"`): the supplier groups (a new order, or the
  existing draft that gets what is missing, with "now -> after" per item),
  the lines that need a supplier chosen (one by one or ticked and assigned at
  once), and the lines with nothing to order. Events: `preview_change`,
  `preview_assign_selected`, `preview_confirm`, `cancel_generation_preview`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrderPlan
  alias PhoenixKitWarehouse.Web.Components.WarehouseBrowser
  alias PhoenixKitWarehouse.Web.SupplierOrderPreview

  attr(:preview, :map, default: nil, doc: "`SupplierOrderPreview` state, `nil` when closed")

  def preview_modal(assigns) do
    assigns =
      case assigns.preview do
        nil -> assigns
        preview -> assign(assigns, :summary, SupplierOrderPreview.summary(preview))
      end

    ~H"""
    <%!-- The default close guard (:confirm) keeps the choices from a stray Esc
         or backdrop click: the form below submits, so it counts. --%>
    <.modal
      :if={@preview}
      id="io-generation-preview"
      show={true}
      on_close="cancel_generation_preview"
      max_width="7xl"
      max_height="85vh"
    >
      <:title>
        <.icon name="hero-truck" class="w-5 h-5" />
        {dgettext("default", "Generate supplier orders")}
      </:title>

      <div
        :if={@preview.stale?}
        id="io-preview-stale"
        role="alert"
        class="alert alert-warning mb-3"
      >
        <.icon name="hero-arrow-path" class="w-5 h-5" />
        <span>{dgettext("default", "The data has changed — check and press again")}</span>
      </div>

      <%!-- The modal's scroll area has no padding of its own: without this
           one the headings and focus rings touch its edge. --%>
      <form
        id="io-generation-preview-form"
        phx-change="preview_change"
        phx-submit="preview_confirm"
        class="flex flex-col gap-5 p-2"
      >
        <section id="io-preview-suppliers" class="flex flex-col gap-3">
          <h3 class="font-semibold text-base">{dgettext("default", "Suppliers")}</h3>
          <p
            :if={@preview.assembled.orders == []}
            class="text-sm text-base-content/60"
          >
            {dgettext("default", "Nothing is ordered yet.")}
          </p>
          <div
            :for={order <- @preview.assembled.orders}
            id={"io-preview-group-#{order.supplier_uuid}"}
            class="rounded-box border border-base-300"
          >
            <div class="flex flex-wrap items-center gap-2 px-3 py-2 bg-base-200 rounded-t-box">
              <span class="font-medium">{order.supplier_name || "—"}</span>
              <%= if order.target == :new do %>
                <span
                  id={"io-preview-group-#{order.supplier_uuid}-new"}
                  class="badge badge-sm badge-success badge-outline"
                >
                  {dgettext("default", "new order")}
                </span>
              <% end %>
            </div>
            <div
              :if={order.target != :new}
              id={"io-preview-group-#{order.supplier_uuid}-target"}
              role="alert"
              class="alert alert-warning rounded-none py-2 text-sm"
            >
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>
                {dgettext(
                  "default",
                  "There is already a draft %{number} for this supplier — what is missing will be added to it",
                  number: "#SO-#{order.target.number}"
                )}
              </span>
            </div>
            <.lines_table preview={@preview} keys={order.keys} order={order} kind={:placed} />
          </div>
        </section>

        <section
          :if={@preview.assembled.unplaced != []}
          id="io-preview-choose"
          class="flex flex-col gap-2"
        >
          <h3 class="font-semibold text-base">{dgettext("default", "Choose a supplier")}</h3>
          <%!-- Stays in view while a long list of lines scrolls under it. --%>
          <div class="sticky top-0 z-10 flex flex-wrap items-center gap-2 py-2 text-sm bg-base-100">
            <label class="flex items-center gap-2 cursor-pointer">
              <input type="hidden" name="pick_all" value="false" />
              <input
                type="checkbox"
                id="io-preview-pick-all"
                name="pick_all"
                value="true"
                class="checkbox checkbox-sm"
                checked={
                  length(@preview.checked) == length(@preview.assembled.unplaced)
                }
              />
              {dgettext("default", "Select all")}
            </label>
            <span class="text-base-content/60">
              {dgettext("default", "Selected: %{n}", n: length(@preview.checked))}
            </span>
            <span class="ml-auto">{dgettext("default", "Assign to the selected:")}</span>
            <select
              id="io-preview-bulk-supplier"
              name="bulk_supplier"
              class="select select-sm w-56"
            >
              <option value="">{dgettext("default", "— select supplier —")}</option>
              <option
                :for={supplier <- @preview.plan.suppliers}
                value={supplier.uuid}
                selected={supplier.uuid == @preview.bulk_supplier}
              >
                {supplier.name}
              </option>
            </select>
            <button
              type="button"
              id="io-preview-assign-selected"
              phx-click="preview_assign_selected"
              disabled={is_nil(@preview.bulk_supplier) or @preview.checked == []}
              class="btn btn-sm btn-outline"
            >
              {dgettext("default", "Assign")}
            </button>
          </div>
          <.lines_table
            preview={@preview}
            keys={Enum.map(@preview.assembled.unplaced, & &1.key)}
            kind={:unplaced}
          />
        </section>

        <details
          :if={@preview.assembled.not_ordered != []}
          id="io-preview-not-ordered"
          class="collapse collapse-arrow bg-base-200"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary class="collapse-title text-sm font-medium">
            {dgettext("default", "Nothing to order (%{n})",
              n: length(@preview.assembled.not_ordered)
            )}
          </summary>
          <div class="collapse-content">
            <.lines_table
              preview={@preview}
              keys={Enum.map(@preview.assembled.not_ordered, & &1.key)}
              kind={:not_ordered}
            />
          </div>
        </details>
      </form>

      <:actions>
        <%!-- Wraps on a phone: the summary takes its own line above the buttons. --%>
        <div class="flex flex-wrap items-center justify-end gap-2 w-full">
          <div id="io-preview-summary" class="grow w-full sm:w-auto min-w-0 text-sm">
            {dgettext(
              "default",
              "New orders: %{created}, appended: %{appended} (lines: %{lines}); not ordered: %{not_ordered}",
              @summary
            )}
          </div>
          <button
            type="button"
            id="io-preview-cancel"
            phx-click="cancel_generation_preview"
            class="btn btn-sm btn-ghost"
          >
            {dgettext("default", "Cancel")}
          </button>
          <button
            type="submit"
            id="io-preview-submit"
            form="io-generation-preview-form"
            disabled={@preview.assembled.orders == []}
            phx-disable-with={dgettext("default", "Generating...")}
            class="btn btn-sm btn-primary"
          >
            <.icon name="hero-truck" class="w-4 h-4" />
            {dgettext("default", "Generate")}
          </button>
        </div>
      </:actions>
    </.modal>
    """
  end

  attr(:preview, :map, required: true)
  attr(:keys, :list, required: true)
  attr(:order, :map, default: nil)
  attr(:kind, :atom, required: true, values: [:placed, :unplaced, :not_ordered])

  defp lines_table(assigns) do
    assigns =
      assign(
        assigns,
        :lines,
        Enum.map(assigns.keys, &SupplierOrderPreview.line(assigns.preview, &1))
      )

    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-xs">
        <thead>
          <tr>
            <th :if={@kind == :unplaced} class="w-8"></th>
            <th>{dgettext("default", "Item")}</th>
            <th>{dgettext("default", "SKU")}</th>
            <th class="text-right">{dgettext("default", "Required")}</th>
            <th class="text-right">{dgettext("default", "Issued")}</th>
            <th class="text-right">{dgettext("default", "On hand")}</th>
            <th class="text-right">{dgettext("default", "Already ordered")}</th>
            <th class="text-right">{dgettext("default", "To order")}</th>
            <th>{dgettext("default", "Unit")}</th>
            <th>{dgettext("default", "Reason")}</th>
            <th :if={@kind != :not_ordered}>{dgettext("default", "Supplier")}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={line <- @lines}
            id={"io-preview-line-#{line.index}"}
            class={["align-top", line.key in @preview.changed && "bg-warning/10"]}
          >
            <td :if={@kind == :unplaced}>
              <input
                type="checkbox"
                id={"io-preview-pick-#{line.index}"}
                name={"pick[#{line.key}]"}
                value="true"
                checked={line.key in @preview.checked}
                class="checkbox checkbox-sm"
              />
            </td>
            <td class="min-w-40 break-words">
              <div class="font-medium">{line.name || "—"}</div>
              <span
                :if={line.key in @preview.changed}
                id={"io-preview-changed-#{line.index}"}
                class="badge badge-xs badge-warning"
              >
                {dgettext("default", "changed")}
              </span>
              <.why line={line} />
            </td>
            <td class="font-mono text-xs">{line.sku}</td>
            <td class="text-right tabular-nums">{qty(line.required)}</td>
            <td class="text-right tabular-nums">{qty(line.issued)}</td>
            <td class="text-right tabular-nums">{qty(line.on_hand)}</td>
            <td class="text-right tabular-nums">{qty(line.in_transit)}</td>
            <td class="text-right tabular-nums font-semibold">
              {qty(line.to_order)}
              <.now_after :if={@order} order={@order} line={line} />
            </td>
            <td class="text-xs">{WarehouseBrowser.unit_label(line.unit)}</td>
            <td id={"io-preview-reason-#{line.index}"} class="text-xs text-base-content/70">
              {reason(line, @preview.choices, @kind)}
            </td>
            <td :if={@kind != :not_ordered}>
              <.supplier_select line={line} preview={@preview} />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:order, :map, required: true)
  attr(:line, :map, required: true)

  defp now_after(assigns) do
    assigns = assign(assigns, :pair, Map.get(assigns.order.now_after, assigns.line.item_uuid))

    ~H"""
    <div
      :if={@pair}
      id={"io-preview-now-after-#{@line.index}"}
      class="text-xs font-normal text-base-content/60 whitespace-nowrap"
    >
      {dgettext("default", "in %{number}: now %{now} → %{after}",
        number: "#SO-#{@order.target.number}",
        now: qty(elem(@pair, 0)),
        after: qty(elem(@pair, 1))
      )}
    </div>
    """
  end

  attr(:line, :map, required: true)

  defp why(assigns) do
    ~H"""
    <details
      :if={@line.explanation || @line.in_transit_from != []}
      id={"io-preview-why-#{@line.index}"}
      class="text-xs"
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="cursor-pointer text-base-content/60">{dgettext("default", "Why")}</summary>
      <div class="mt-1 space-y-1 text-base-content/70">
        <div :for={from <- @line.in_transit_from}>{in_transit_text(from)}</div>
        <div :if={@line.explanation} class="whitespace-pre-line">{@line.explanation}</div>
      </div>
    </details>
    """
  end

  attr(:line, :map, required: true)
  attr(:preview, :map, required: true)

  defp supplier_select(assigns) do
    candidate_uuids = Enum.map(assigns.line.candidates, & &1.uuid)

    assigns =
      assigns
      |> assign(:current, current_choice(assigns.line, assigns.preview.choices))
      |> assign(
        :others,
        Enum.reject(assigns.preview.plan.suppliers, &(&1.uuid in candidate_uuids))
      )

    ~H"""
    <select
      id={"io-preview-choice-#{@line.index}"}
      name={"choice[#{@line.key}]"}
      class="select select-xs w-full min-w-32"
    >
      <option value="skip" selected={@current == "skip"}>
        {dgettext("default", "— do not order —")}
      </option>
      <optgroup :if={@line.candidates != []} label={dgettext("default", "Suppliers of the item")}>
        <option
          :for={candidate <- @line.candidates}
          value={candidate.uuid}
          selected={candidate.uuid == @current}
        >
          {candidate.name} · {source_label(candidate.sources)}
        </option>
      </optgroup>
      <optgroup label={dgettext("default", "All suppliers")}>
        <option :for={supplier <- @others} value={supplier.uuid} selected={supplier.uuid == @current}>
          {supplier.name}
        </option>
      </optgroup>
    </select>
    """
  end

  defp current_choice(line, choices) do
    case Map.get(choices, line.key) do
      nil -> SupplierOrderPlan.default_supplier_uuid(line) || "skip"
      choice -> choice
    end
  end

  # ---------------------------------------------------------------------------
  # Texts
  # ---------------------------------------------------------------------------

  defp reason(line, _choices, :not_ordered), do: not_ordered_reason(line)

  defp reason(line, choices, _kind) do
    case Map.get(choices, line.key) do
      "skip" -> dgettext("default", "Not ordered: chosen by hand")
      nil -> supplier_reason(line)
      _uuid -> dgettext("default", "Chosen by hand")
    end
  end

  defp supplier_reason(%{preselected: %{number: number}}),
    do: dgettext("default", "As in %{number}", number: "#SO-#{number}")

  defp supplier_reason(%{reason: :primary}),
    do: dgettext("default", "Primary supplier of the item")

  defp supplier_reason(%{reason: :single_candidate, reason_source: :item_link}),
    do: dgettext("default", "The only supplier of the item")

  defp supplier_reason(%{reason: :single_candidate}),
    do: dgettext("default", "The only supplier of the manufacturer")

  defp supplier_reason(%{reason: :ambiguous}),
    do: dgettext("default", "Several suppliers — choose one")

  defp supplier_reason(%{reason: :no_supplier, primary_issue: :unresolved}),
    do:
      dgettext(
        "default",
        "No supplier: the primary supplier is not among the warehouse suppliers"
      )

  defp supplier_reason(%{reason: :no_supplier, primary_issue: :inactive}),
    do: dgettext("default", "No supplier: the primary supplier is inactive")

  defp supplier_reason(%{reason: :no_supplier}),
    do: dgettext("default", "No supplier found for the item")

  defp supplier_reason(%{reason: :no_item}),
    do: dgettext("default", "The item is not in the catalogue")

  defp not_ordered_reason(%{reason: :no_item}),
    do: dgettext("default", "The item is not in the catalogue")

  defp not_ordered_reason(%{zero_reason: :issued}), do: dgettext("default", "Already issued")
  defp not_ordered_reason(%{zero_reason: :on_hand}), do: dgettext("default", "Covered by stock")
  defp not_ordered_reason(%{zero_reason: :no_need}), do: dgettext("default", "Nothing required")

  defp not_ordered_reason(%{zero_reason: :in_transit} = line) do
    dgettext("default", "Already ordered in %{numbers}",
      numbers: Enum.map_join(line.in_transit_from, ", ", &order_label/1)
    )
  end

  defp not_ordered_reason(_line), do: "—"

  # A draft without a supplier is named as such (it still counts as ordered).
  defp in_transit_text(%{status: "draft", supplier_uuid: nil} = from) do
    dgettext("default", "Already ordered in draft %{number} without supplier: %{quantity}",
      number: "#SO-#{from.number}",
      quantity: qty(from.quantity)
    )
  end

  defp in_transit_text(from) do
    dgettext("default", "Already ordered in %{number} (%{status}): %{quantity}",
      number: "#SO-#{from.number}",
      status: status_label(from.status),
      quantity: qty(from.quantity)
    )
  end

  defp order_label(%{status: "draft", supplier_uuid: nil, number: number}),
    do: dgettext("default", "%{number} (draft without supplier)", number: "#SO-#{number}")

  defp order_label(%{number: number}), do: "#SO-#{number}"

  defp source_label(sources) do
    cond do
      :primary in sources -> dgettext("default", "primary")
      :item_link in sources -> dgettext("default", "item's supplier")
      true -> dgettext("default", "manufacturer's supplier")
    end
  end

  defp status_label("draft"), do: dgettext("default", "Draft")
  defp status_label("posted"), do: dgettext("default", "Posted")
  defp status_label(other), do: other

  defp qty(value), do: StockLedger.format_quantity(value)
end
