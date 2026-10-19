defmodule PhoenixKitWarehouse.Web.Components.RelatedDocuments do
  @moduledoc """
  Shared "related documents" card fragment for warehouse document forms.

  Consolidates the upstream/downstream link blocks that were duplicated
  inline in `InternalOrderFormLive` and `SupplierOrderFormLive` (§7 list-MVP
  of the warehouse traceability model):

    * `upstream` — documents this one was imported from or manually linked
      to via `PhoenixKitWarehouse.SourceKinds`. Always rendered, even when
      empty, because the block also carries the "Attach" control
      (`phx-click="open_link_picker"`) that lets the keeper add the first
      link; each attached ref gets a "remove" button
      (`phx-click="remove_source_ref"`, `phx-value-type`, `phx-value-uuid`).
    * `downstream` — documents created *from* this one (e.g. a Goods Receipt
      spawned from a Supplier Order). Read-only — no attach/remove controls —
      and the whole block is skipped when the list is empty.

  Both attrs take the ref-map shape produced by `PhoenixKitWarehouse.DocRefs`:
  `%{label:, path:, uuid:, kind:}`. The calling LiveView owns the
  `open_link_picker` / `remove_source_ref` event handlers and the
  `source_refs` / child-refs assigns that feed this component — this module
  only renders.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr(:upstream, :list, required: true, doc: "Editable ref maps, e.g. @source_refs")
  attr(:downstream, :list, required: true, doc: "Read-only ref maps; block hidden when empty")
  attr(:upstream_label, :string, required: true)
  attr(:downstream_label, :string, required: true)

  attr(:read_only, :boolean,
    default: false,
    doc: "Hides the attach and remove controls (a document in the trash)"
  )

  def related_documents(assigns) do
    ~H"""
    <div class="divider my-1"></div>
    <div class="text-sm">
      <p class="text-base-content/60 font-medium mb-2 flex items-center gap-1">
        {@upstream_label}
        <button
          :if={!@read_only}
          type="button"
          phx-click="open_link_picker"
          class="btn btn-2xs btn-ghost btn-circle"
          title={dgettext("default", "Attach")}
        >
          <.icon name="hero-plus" class="w-3 h-3" />
        </button>
      </p>
      <div class="flex flex-wrap gap-2">
        <span :if={@upstream == []} class="text-base-content/30 text-sm">—</span>
        <%= for ref <- @upstream do %>
          <span class="inline-flex items-center gap-1 bg-base-200 rounded px-2 py-0.5">
            <.link navigate={ref.path} class="link link-primary font-mono text-sm">
              {ref.label}
            </.link>
            <button
              :if={!@read_only}
              type="button"
              phx-click="remove_source_ref"
              phx-value-type={ref.kind}
              phx-value-uuid={ref.uuid}
              class="text-base-content/40 hover:text-error"
            >
              <.icon name="hero-x-mark" class="w-3 h-3" />
            </button>
          </span>
        <% end %>
      </div>
    </div>
    <%= if @downstream != [] do %>
      <div class="divider my-1"></div>
      <div class="text-sm">
        <p class="text-base-content/60 font-medium mb-2">
          {@downstream_label}
        </p>
        <div class="flex flex-wrap gap-2">
          <%= for ref <- @downstream do %>
            <.link navigate={ref.path} class="link link-primary font-mono text-sm">
              {ref.label}
            </.link>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end
end
