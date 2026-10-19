defmodule PhoenixKitWarehouse.Web.TrashMessages do
  @moduledoc false
  # The flash texts and labels the trash views of the internal and supplier
  # order LiveViews share.

  use Gettext, backend: PhoenixKitWarehouse.Gettext

  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.SupplierOrder

  @doc "The label of a document as the lists print it (`#IO-12`, `#SO-7`)."
  def tag(%InternalOrder{number: number}), do: "#IO-#{number}"
  def tag(%SupplierOrder{number: number}), do: "#SO-#{number}"

  @doc "The flash after a restore: the document, and the drafts that went to the trash for it."
  def restored(order, superseded) do
    dgettext("default", "%{document} restored from the trash.", document: tag(order))
    |> append_moved(superseded)
  end

  @doc "Appends the \"moved to the trash\" sentence to `message` when `orders` is not empty."
  def append_moved(message, []), do: message

  def append_moved(message, orders) do
    message <>
      " " <>
      dgettext("default", "Moved to the trash: %{numbers}.",
        numbers: Enum.map_join(orders, ", ", &tag/1)
      )
  end

  def restore_error(:not_deleted), do: dgettext("default", "This document is not in the trash")
  def restore_error(:not_draft), do: dgettext("default", "Only drafts can be restored")
  def restore_error(:not_found), do: dgettext("default", "Document not found")
  def restore_error(_reason), do: dgettext("default", "Failed to restore the document")

  @doc "The flash for a write that found the document in the trash."
  def moved_to_trash, do: dgettext("default", "Document moved to the trash")

  @doc "The banner text of a trashed document's form."
  def banner(deleted_at, user_label) do
    dgettext("default", "This document is in the trash (deleted %{date} by %{user}).",
      date: Calendar.strftime(deleted_at, "%d.%m.%Y"),
      user: user_label
    )
  end
end
