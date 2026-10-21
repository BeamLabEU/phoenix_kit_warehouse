defmodule PhoenixKitWarehouse.Web.Components.TrashAction do
  @moduledoc """
  The "Move to trash" pieces of the warehouse document lists and forms: the
  row menu with its items, the form button, the banner of a trashed document
  and the confirmation. The events they send are handled by
  `PhoenixKitWarehouse.Web.TrashActions`.

  `id_prefix` keeps the ids apart: the document kind (`io`, `so`, `gr`, `gi`,
  `tr`, `inv`) in a table row or a form, `<kind>-card` in a card of the same
  list, which `table_default` keeps in the DOM next to the table.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]

  import PhoenixKitWeb.Components.Core.TableRowMenu,
    only: [table_row_menu: 1, table_row_menu_button: 1, table_row_menu_link: 1]

  alias PhoenixKitWarehouse.Web.TrashMessages

  attr(:id_prefix, :string,
    required: true,
    doc: "e.g. \"io\" in a table row, \"io-card\" in a card"
  )

  attr(:menu_id, :string,
    default: nil,
    doc: "the menu's id; `<id_prefix>-menu-<uuid>` when nil"
  )

  attr(:href, :string, required: true, doc: "the document's form, for Edit / Open")
  attr(:view, :string, required: true, doc: "the list's tab: \"active\" or \"trash\"")

  attr(:entry, :map,
    required: true,
    doc: "the list entry: `uuid`, `status` and `blocked_reason` (`TrashActions.blocked_reason/1`)"
  )

  @doc """
  The ⋮ menu of a list row: Edit (Open in the trash view), then Move to trash
  on the active tab or, for a trashed draft, Restore. The card view renders it
  again under its own `id_prefix`, so no id repeats on the page.
  """
  def row_menu(assigns) do
    assigns =
      assign(
        assigns,
        :menu_id,
        assigns.menu_id || "#{assigns.id_prefix}-menu-#{assigns.entry.uuid}"
      )

    ~H"""
    <.table_row_menu id={@menu_id}>
      <.table_row_menu_link
        navigate={@href}
        icon={if @view == "trash", do: "hero-eye", else: "hero-pencil-square"}
        label={
          if @view == "trash",
            do: dgettext("default", "Open"),
            else: dgettext("default", "Edit")
        }
      />
      <.trash_menu_item
        :if={@view == "active"}
        id_prefix={@id_prefix}
        uuid={@entry.uuid}
        reason={@entry.blocked_reason}
      />
      <.restore_menu_item
        :if={@view == "trash" and @entry.status == "draft"}
        id_prefix={@id_prefix}
        uuid={@entry.uuid}
      />
    </.table_row_menu>
    """
  end

  attr(:id_prefix, :string,
    required: true,
    doc: "e.g. \"io\" in a table row, \"io-card\" in a card"
  )

  attr(:uuid, :string, required: true, doc: "the document; sent as `phx-value-uuid`")

  attr(:reason, :string,
    default: nil,
    doc:
      "why the document cannot go to the trash (`TrashActions.blocked_reason/1`); nil when it can"
  )

  @doc """
  The "Move to trash" item of a `table_row_menu`. A document that may go sends
  `request_trash` (`#<id_prefix>-trash-<uuid>`); one that may not gets the same
  item disabled, with the reason written under it
  (`#<id_prefix>-trash-reason-<uuid>`) and as its title.
  """
  def trash_menu_item(%{reason: nil} = assigns) do
    ~H"""
    <.table_row_menu_button
      id={"#{@id_prefix}-trash-#{@uuid}"}
      phx-click="request_trash"
      phx-value-uuid={@uuid}
      icon="hero-trash"
      variant="error"
      label={dgettext("default", "Move to trash")}
    />
    """
  end

  def trash_menu_item(assigns) do
    ~H"""
    <li role="none">
      <button
        type="button"
        role="menuitem"
        id={"#{@id_prefix}-trash-#{@uuid}"}
        disabled
        aria-disabled="true"
        aria-describedby={"#{@id_prefix}-trash-reason-#{@uuid}"}
        title={@reason}
        class="flex items-start gap-2 px-3 py-2 rounded-lg text-sm w-full text-left text-base-content/50 cursor-not-allowed"
      >
        <.icon name="hero-trash" class="w-4 h-4 shrink-0 opacity-70 mt-0.5" />
        <span class="flex flex-col gap-0.5">
          <span>{dgettext("default", "Move to trash")}</span>
          <span
            id={"#{@id_prefix}-trash-reason-#{@uuid}"}
            class="text-xs text-warning max-w-[14rem] whitespace-normal"
          >
            {@reason}
          </span>
        </span>
      </button>
    </li>
    """
  end

  attr(:id_prefix, :string,
    required: true,
    doc: "e.g. \"io\" in a table row, \"io-card\" in a card"
  )

  attr(:uuid, :string, required: true, doc: "the trashed draft; sent as `phx-value-uuid`")

  @doc "The Restore item of a trashed draft's `table_row_menu` (`#<id_prefix>-restore-<uuid>`)."
  def restore_menu_item(assigns) do
    ~H"""
    <.table_row_menu_button
      id={"#{@id_prefix}-restore-#{@uuid}"}
      phx-click="restore"
      phx-disable-with={dgettext("default", "Restoring...")}
      phx-value-uuid={@uuid}
      icon="hero-arrow-uturn-left"
      label={dgettext("default", "Restore")}
    />
    """
  end

  attr(:id_prefix, :string, required: true, doc: "the document kind, e.g. \"io\"")

  attr(:reason, :string,
    default: nil,
    doc:
      "why the document cannot go to the trash (`TrashActions.blocked_reason/1`); nil when it can"
  )

  @doc """
  The "Move to trash" button of a form (`#<id_prefix>-trash`), sending
  `request_trash` for the form's own document. When the document may not go,
  the button is disabled and the reason shows as a tooltip on its wrapper (a
  disabled button gets no hover) and is read out through `aria-describedby`.
  """
  def trash_button(%{reason: nil} = assigns) do
    ~H"""
    <button
      type="button"
      id={"#{@id_prefix}-trash"}
      phx-click="request_trash"
      class="btn btn-sm btn-error btn-outline"
    >
      <.icon name="hero-trash" class="w-4 h-4" /> {dgettext("default", "Move to trash")}
    </button>
    """
  end

  def trash_button(assigns) do
    ~H"""
    <span class="tooltip tooltip-bottom" data-tip={@reason}>
      <button
        type="button"
        id={"#{@id_prefix}-trash"}
        disabled
        aria-describedby={"#{@id_prefix}-trash-reason"}
        class="btn btn-sm btn-error btn-outline"
      >
        <.icon name="hero-trash" class="w-4 h-4" /> {dgettext("default", "Move to trash")}
      </button>
      <span id={"#{@id_prefix}-trash-reason"} class="sr-only">{@reason}</span>
    </span>
    """
  end

  attr(:id_prefix, :string, required: true, doc: "the document kind, e.g. \"io\"")
  attr(:document, :map, required: true, doc: "the trashed document of the form")
  attr(:deleted_by, :string, default: nil, doc: "who moved it to the trash, as a label")

  @doc """
  The banner of a trashed document's form (`#<id_prefix>-trash-banner`): when
  and by whom it was deleted, and for a draft the Restore button
  (`#<id_prefix>-restore`), which sends `restore`.
  """
  def trash_banner(assigns) do
    ~H"""
    <div id={"#{@id_prefix}-trash-banner"} class="alert alert-warning">
      <.icon name="hero-trash" class="w-5 h-5" />
      <span>{TrashMessages.banner(@document.deleted_at, @deleted_by)}</span>
      <button
        :if={@document.status == "draft"}
        type="button"
        id={"#{@id_prefix}-restore"}
        phx-click="restore"
        phx-disable-with={dgettext("default", "Restoring...")}
        class="btn btn-sm btn-primary"
      >
        <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {dgettext("default", "Restore")}
      </button>
    </div>
    """
  end

  attr(:id_prefix, :string, required: true, doc: "the document kind, e.g. \"io\"")
  attr(:candidate, :any, required: true, doc: "the document waiting for the confirmation, or nil")
  attr(:form, :boolean, default: false, doc: "in a form: also warn that unsaved changes are lost")

  @doc """
  The confirmation (`confirm_modal`), open while there is a candidate; it
  sends `confirm_trash` or `cancel_trash`. The document is named in
  `#<id_prefix>-trash-confirm-doc`.
  """
  def trash_confirm(assigns) do
    ~H"""
    <.confirm_modal
      show={@candidate != nil}
      on_confirm="confirm_trash"
      on_cancel="cancel_trash"
      title={dgettext("default", "Move to the trash?")}
      title_icon="hero-trash"
      confirm_text={dgettext("default", "Move to trash")}
      confirm_icon="hero-trash"
      prompt={if @form, do: dgettext("default", "Unsaved changes in the form will not be saved."), else: ""}
      danger
    >
      <p :if={@candidate} id={"#{@id_prefix}-trash-confirm-doc"} class="text-sm">
        {dgettext(
          "default",
          "Move to the trash: %{document}. The document can be restored on the Trash tab.",
          document: TrashMessages.tag(@candidate)
        )}
      </p>
    </.confirm_modal>
    """
  end
end
