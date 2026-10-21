defmodule PhoenixKitWarehouse.Web.TrashActions do
  @moduledoc """
  "Move to trash" for the lists and forms of the warehouse documents: the
  document kinds, the reason a document cannot go to the trash, the three
  events behind the confirmation, the restore, and what a form does while its
  document is in the trash (`refuse_trashed/4`, `trashed_meanwhile/2`,
  `resume_files_tab/2`, `deleted_by_name/1`).

  A LiveView keeps `:trash_candidate` (the document waiting for the
  confirmation, `nil` otherwise), renders the pieces of
  `PhoenixKitWarehouse.Web.Components.TrashAction`, and forwards the events,
  one line each:

      def handle_event("request_trash", %{"uuid" => uuid}, socket),
        do: {:noreply, TrashActions.request_trash(socket, :internal_order, uuid, &assign_orders/1)}

      def handle_event("confirm_trash", _params, socket),
        do: {:noreply, TrashActions.confirm_trash(socket, :internal_order, &assign_orders/1)}

      def handle_event("cancel_trash", _params, socket),
        do: {:noreply, TrashActions.cancel_trash(socket)}

  The kind comes from the LiveView, never from the browser; only the uuid
  does, and the document is read again and checked on the server. The last
  argument reloads what the page shows (the list, or the form's document) after
  a move or a refusal. Who may do it is who may open the page: there is no
  separate permission.
  """

  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias PhoenixKit.Users.Auth.Scope

  alias PhoenixKitWarehouse.{
    GoodsIssue,
    GoodsIssues,
    GoodsReceipt,
    GoodsReceipts,
    InternalOrder,
    InternalOrders,
    Inventories,
    InventoryDocument,
    SupplierOrder,
    SupplierOrders,
    Transfer,
    Transfers
  }

  alias PhoenixKitWarehouse.Web.{TrashMessages, UserNames}

  @type kind_name ::
          :internal_order
          | :supplier_order
          | :goods_receipt
          | :goods_issue
          | :inventory
          | :transfer

  @typep socket_fun :: (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())

  @type kind :: %{
          required(:get) => (Ecto.UUID.t() -> {:ok, struct()} | {:error, :not_found}),
          required(:soft_delete) => (struct(), Ecto.UUID.t() | nil ->
                                       {:ok, struct()} | {:error, atom()}),
          optional(:restore) => (struct(), Ecto.UUID.t() | nil ->
                                   {:ok, struct()} | {:error, atom()})
        }

  # The kinds restored without a swap: the ones with `restore` in `kind/1`.
  @restorable_kinds [:goods_receipt, :goods_issue, :inventory, :transfer]

  # The kinds whose documents are posted (a transfer moves through its own
  # statuses instead).
  @posting_schemas [InternalOrder, SupplierOrder, GoodsReceipt, GoodsIssue, InventoryDocument]

  @doc """
  The description of a document kind: `get/1`, `soft_delete/2` and, for the
  kinds restored without a swap (all but internal and supplier orders),
  `restore/2` of its context.
  """
  @spec kind(kind_name()) :: kind()
  def kind(:internal_order) do
    %{
      get: &InternalOrders.get_internal_order/1,
      soft_delete: &InternalOrders.soft_delete_internal_order/2
    }
  end

  def kind(:supplier_order) do
    %{
      get: &SupplierOrders.get_supplier_order/1,
      soft_delete: &SupplierOrders.soft_delete_supplier_order/2
    }
  end

  def kind(:goods_receipt) do
    %{
      get: &GoodsReceipts.get_goods_receipt/1,
      soft_delete: &GoodsReceipts.soft_delete/2,
      restore: &GoodsReceipts.restore_goods_receipt/2
    }
  end

  def kind(:goods_issue) do
    %{
      get: &GoodsIssues.get_goods_issue/1,
      soft_delete: &GoodsIssues.soft_delete/2,
      restore: &GoodsIssues.restore_goods_issue/2
    }
  end

  def kind(:inventory) do
    %{
      get: &Inventories.get_document/1,
      soft_delete: &Inventories.soft_delete_document/2,
      restore: &Inventories.restore_document/2
    }
  end

  def kind(:transfer) do
    %{
      get: &Transfers.get_transfer/1,
      soft_delete: &Transfers.soft_delete_transfer/2,
      restore: &Transfers.restore_transfer/2
    }
  end

  @doc """
  Why `document` cannot go to the trash, or `nil` when it can (a live draft).
  The one source of these texts for the menu items, the form buttons and the
  flashes.
  """
  @spec blocked_reason(struct()) :: String.t() | nil
  def blocked_reason(%{deleted_at: %DateTime{}}), do: already_in_trash()

  def blocked_reason(%{status: "draft"}), do: nil

  def blocked_reason(%schema{status: "posted"}) when schema in @posting_schemas,
    do: dgettext("default", "A posted document cannot be deleted")

  def blocked_reason(%Transfer{status: "in_transit"}),
    do: dgettext("default", "A transfer in transit cannot be deleted — cancel it first")

  def blocked_reason(%Transfer{status: "done"}),
    do: dgettext("default", "A completed transfer cannot be deleted")

  def blocked_reason(%Transfer{status: "cancelled"}),
    do: dgettext("default", "A cancelled transfer cannot be deleted")

  def blocked_reason(_document), do: cannot_delete()

  @doc """
  The `request_trash` event: reads the document of `kind` behind `uuid` and,
  if it may go to the trash, keeps it as the candidate the confirmation names.
  Otherwise the flash says why (a malformed or unknown uuid is "Document not
  found"), no confirmation opens, and `reload` redraws the page.
  """
  @spec request_trash(
          Phoenix.LiveView.Socket.t(),
          kind_name(),
          term(),
          (Phoenix.LiveView.Socket.t() ->
             Phoenix.LiveView.Socket.t())
        ) ::
          Phoenix.LiveView.Socket.t()
  def request_trash(socket, kind_name, uuid, reload) do
    with {:ok, uuid} <- cast_uuid(uuid),
         {:ok, document} <- kind(kind_name).get.(uuid),
         nil <- blocked_reason(document) do
      assign(socket, :trash_candidate, document)
    else
      {:error, :not_found} -> refuse(socket, not_found(), reload)
      reason when is_binary(reason) -> refuse(socket, reason, reload)
    end
  end

  @doc """
  The `confirm_trash` event: moves the candidate to the trash as the current
  user, says so (or why not), and calls `reload`. Without a candidate (a
  double click, a repeated event) it does nothing.
  """
  @spec confirm_trash(Phoenix.LiveView.Socket.t(), kind_name(), (Phoenix.LiveView.Socket.t() ->
                                                                   Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def confirm_trash(%{assigns: %{trash_candidate: nil}} = socket, _kind_name, _reload), do: socket

  def confirm_trash(%{assigns: %{trash_candidate: document}} = socket, kind_name, reload) do
    kind = kind(kind_name)
    socket = assign(socket, :trash_candidate, nil)

    case kind.soft_delete.(document, actor_uuid(socket)) do
      {:ok, trashed} ->
        socket |> put_flash(:info, TrashMessages.moved(trashed)) |> reload.()

      {:error, reason} ->
        socket |> put_flash(:error, error_message(kind, document, reason)) |> reload.()
    end
  end

  @doc """
  The `restore` event of a goods receipt, goods issue, stocktake or transfer:
  brings the trashed draft of `kind` behind `uuid` back as the current user,
  says so (or why not), and calls `reload`. A restored goods issue that now
  holds more of an internal order than it has gets a warning naming the order
  (`GoodsIssues.overcommitted_internal_orders/1`); the restore stands.
  """
  @spec restore(
          Phoenix.LiveView.Socket.t(),
          :goods_receipt | :goods_issue | :inventory | :transfer,
          term(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
        ) :: Phoenix.LiveView.Socket.t()
  def restore(socket, kind_name, uuid, reload) when kind_name in @restorable_kinds do
    kind = kind(kind_name)

    with {:ok, uuid} <- cast_uuid(uuid),
         {:ok, document} <- kind.get.(uuid),
         {:ok, restored} <- kind.restore.(document, actor_uuid(socket)) do
      socket |> put_flash(:info, restored_message(restored)) |> reload.()
    else
      {:error, reason} ->
        socket |> put_flash(:error, TrashMessages.restore_error(reason)) |> reload.()
    end
  end

  defp restored_message(%GoodsIssue{} = issue) do
    issue
    |> TrashMessages.restored([])
    |> TrashMessages.append_overcommitted(GoodsIssues.overcommitted_internal_orders(issue))
  end

  defp restored_message(document), do: TrashMessages.restored(document, [])

  @doc "The `cancel_trash` event: closes the confirmation."
  @spec cancel_trash(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def cancel_trash(socket), do: assign(socket, :trash_candidate, nil)

  @doc """
  Who moved `document` to the trash, as a label for the form's banner; `nil`
  for a live document.
  """
  @spec deleted_by_name(struct()) :: String.t() | nil
  def deleted_by_name(%{deleted_at: nil}), do: nil

  def deleted_by_name(document) do
    UserNames.label(UserNames.resolve([document], [:deleted_by_uuid]), document.deleted_by_uuid)
  end

  @doc """
  A form's answer to a write event while its document (`socket.assigns[key]`)
  is in the trash. The socket may be a tab behind: the document could have
  been restored meanwhile, so `reload` reads it again. A trashed one gets the
  "moved to the trash" flash; a live one is drawn as such and `resume` picks
  the Files tab up again. Either way the event, meant for the form as it was,
  is not carried out.
  """
  @spec refuse_trashed(Phoenix.LiveView.Socket.t(), atom(), socket_fun(), socket_fun()) ::
          Phoenix.LiveView.Socket.t()
  def refuse_trashed(socket, key, reload, resume) do
    socket = reload.(socket)

    case socket.assigns[key] do
      %{deleted_at: %DateTime{}} -> put_flash(socket, :error, TrashMessages.moved_to_trash())
      _live -> resume.(socket)
    end
  end

  @doc """
  A write of a form found its document in the trash (moved there meanwhile):
  says so, and `reload` draws the stored document rather than the unsaved
  buffer.
  """
  @spec trashed_meanwhile(Phoenix.LiveView.Socket.t(), socket_fun()) ::
          Phoenix.LiveView.Socket.t()
  def trashed_meanwhile(socket, reload) do
    socket
    |> put_flash(:error, TrashMessages.moved_to_trash())
    |> reload.()
  end

  @doc """
  After a restore: the Files tab skipped the folder lookup while the document
  was in the trash, so `start` (the form's folder lookup) runs when that tab is
  open, and the tab does not stay empty.
  """
  @spec resume_files_tab(Phoenix.LiveView.Socket.t(), socket_fun()) ::
          Phoenix.LiveView.Socket.t()
  def resume_files_tab(%{assigns: %{active_tab: :files}} = socket, start), do: start.(socket)
  def resume_files_tab(socket, _start), do: socket

  defp refuse(socket, message, reload) do
    socket
    |> assign(:trash_candidate, nil)
    |> put_flash(:error, message)
    |> reload.()
  end

  # `:not_draft` comes from the locked row, which may differ from the
  # candidate read when the confirmation opened: name the reason of the
  # document as it is now.
  defp error_message(kind, document, :not_draft) do
    case kind.get.(document.uuid) do
      {:ok, fresh} -> blocked_reason(fresh) || cannot_delete()
      {:error, :not_found} -> not_found()
    end
  end

  defp error_message(_kind, _document, :deleted), do: already_in_trash()
  defp error_message(_kind, _document, :not_found), do: not_found()
  defp error_message(_kind, _document, _reason), do: cannot_delete()

  defp already_in_trash, do: dgettext("default", "The document is already in the trash")
  defp cannot_delete, do: dgettext("default", "This document cannot be deleted")
  defp not_found, do: TrashMessages.restore_error(:not_found)

  # The uuid comes from the browser; a malformed one is a document that is not
  # there, not a query error.
  defp cast_uuid(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp actor_uuid(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    case scope && Scope.user(scope) do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end
end
