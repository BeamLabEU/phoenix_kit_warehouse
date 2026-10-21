defmodule PhoenixKitWarehouse.Web.TrashMessages do
  @moduledoc false
  # The flash texts and labels the trash views of the warehouse document
  # LiveViews share. The sentences name the document after a colon, so they
  # need no gendered verb: in ru/uk a stocktake is feminine, the rest masculine.

  use Gettext, backend: PhoenixKitWarehouse.Gettext

  alias PhoenixKitWarehouse.{
    GoodsIssue,
    GoodsReceipt,
    InternalOrder,
    InventoryDocument,
    SupplierOrder,
    Transfer
  }

  @doc """
  The label of a document as the lists print it (`#IO-12`, `#SO-7`, `#GR-3`,
  `#GI-4`, `#TR-5`); a stocktake, listed as a bare `#6`, is named
  "Inventory #6" so a flash says what it is.
  """
  def tag(%InternalOrder{number: number}), do: "#IO-#{number}"
  def tag(%SupplierOrder{number: number}), do: "#SO-#{number}"
  def tag(%GoodsReceipt{number: number}), do: "#GR-#{number}"
  def tag(%GoodsIssue{number: number}), do: "#GI-#{number}"
  def tag(%Transfer{number: number}), do: "#TR-#{number}"

  def tag(%InventoryDocument{number: number}),
    do: dgettext("default", "Inventory #%{number}", number: number)

  @doc "The flash after a move to the trash."
  def moved(document),
    do: dgettext("default", "Moved to the trash: %{document}.", document: tag(document))

  @doc "The flash after a restore: the document, and the drafts that went to the trash for it."
  def restored(order, superseded) do
    dgettext("default", "Restored from the trash: %{document}.", document: tag(order))
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

  @doc """
  Appends the warning that goods issues now hold more of `orders` (internal
  orders) than they have, when `orders` is not empty.
  """
  def append_overcommitted(message, []), do: message

  def append_overcommitted(message, orders) do
    message <>
      " " <>
      dgettext("default", "Goods issues exceed the order for: %{numbers} — check the lines.",
        numbers: Enum.map_join(orders, ", ", &tag/1)
      )
  end

  def restore_error(:not_deleted), do: dgettext("default", "This document is not in the trash")
  def restore_error(:not_draft), do: dgettext("default", "Only drafts can be restored")
  def restore_error(:not_found), do: dgettext("default", "Document not found")
  def restore_error(_reason), do: dgettext("default", "Failed to restore the document")

  @doc "The flash for a write that found the document in the trash."
  def moved_to_trash, do: dgettext("default", "Document moved to the trash")

  @doc """
  The Deleted / Deleted by fields a list card adds in the trash view (`[]` on
  the active tab); `entry` carries `deleted_at` and the `deleted_by` label.
  """
  def card_fields("trash", entry) do
    [
      %{label: dgettext("default", "Deleted"), value: fmt_date(entry.deleted_at)},
      %{label: dgettext("default", "Deleted by"), value: entry.deleted_by}
    ]
  end

  def card_fields(_view, _entry), do: []

  defp fmt_date(nil), do: "—"
  defp fmt_date(dt), do: Calendar.strftime(dt, "%d.%m.%Y")

  @doc "The banner text of a trashed document's form."
  def banner(deleted_at, user_label) do
    dgettext("default", "This document is in the trash (deleted %{date} by %{user}).",
      date: Calendar.strftime(deleted_at, "%d.%m.%Y"),
      user: user_label
    )
  end
end
