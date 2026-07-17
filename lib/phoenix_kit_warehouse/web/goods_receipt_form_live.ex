defmodule PhoenixKitWarehouse.Web.GoodsReceiptFormLive do
  @moduledoc """
  LiveView for creating and editing goods receipts.

  Handles:
  - `:new`      — creates an empty draft and redirects to :edit.
  - `:edit`     — loads an existing receipt; :general tab.
  - `:lines`    — verification sheet: ordered_quantity (read-only) beside editable received_quantity.
  - `:files`    — MediaBrowser; storage folder resolved asynchronously.
  - `:comments` — goods receipt comments thread.

  Uses the admin-chrome pattern: `use PhoenixKitWeb, :live_view` +
  `<.admin_page_header>`. No `<Layouts.app>`, no streams.
  All navigation paths wrapped in `PhoenixKit.Utils.Routes.path/1`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWarehouse.Gettext
  use PhoenixKitComments.Embed

  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.DocRefs
  alias PhoenixKitWarehouse.Comments
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.StorageFolders
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Web.Components.{CommentsPanel, WarehouseBrowser}

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.CostProposals

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    current_user = scope && PhoenixKit.Users.Auth.Scope.user(scope)
    admin? = !!(scope && PhoenixKit.Users.Auth.Scope.admin?(scope))

    comments_available? = Comments.available?()

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:admin?, admin?)
      |> assign(:receipt, nil)
      |> assign(:lines, [])
      |> assign(:note, "")
      |> assign(:active_tab, :general)
      |> assign(:files_scope_folder_uuid, nil)
      |> assign(:files_folder_loading, false)
      |> assign(:comments_available?, comments_available?)
      |> assign(:comment_count, 0)
      |> assign(:comments_subscribed?, false)
      |> assign(:supplier_name, nil)
      |> assign(:location_name, nil)
      |> assign(:supplier_order_ref, nil)
      |> assign(:refs_by_kind, %{})
      |> assign(:show_source_picker, false)
      |> assign(:picker_purpose, :import)
      |> assign(:source_picker_all, [])
      |> assign(:source_picker_candidates, [])
      |> assign(:source_picker_selected_uuids, [])
      |> assign(:source_picker_selected_meta, %{})
      |> assign(:source_picker_query, "")
      |> assign(:warehouses, StockLedger.list_warehouses())
      |> assign(:page_title, dgettext("default", "Goods Receipt"))
      |> assign(:price_proposals, [])
      |> PhoenixKitWeb.Components.MediaBrowser.setup_uploads()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action

    case action do
      :new ->
        handle_params_new(socket)

      :edit ->
        uuid = params["uuid"]
        socket = load_receipt_into_socket(socket, uuid)

        {:noreply,
         socket |> assign(:active_tab, :general) |> maybe_subscribe_and_refresh_comments()}

      :lines ->
        uuid = params["uuid"]
        socket = load_receipt_into_socket(socket, uuid)

        {:noreply,
         socket |> assign(:active_tab, :lines) |> maybe_subscribe_and_refresh_comments()}

      :files ->
        uuid = params["uuid"]
        socket = load_receipt_into_socket(socket, uuid)

        {:noreply,
         socket
         |> assign(:active_tab, :files)
         |> maybe_start_files_folder_resolution()
         |> maybe_subscribe_and_refresh_comments()}

      :comments ->
        uuid = params["uuid"]
        socket = load_receipt_into_socket(socket, uuid)

        {:noreply,
         socket
         |> assign(:active_tab, :comments)
         |> maybe_subscribe_and_refresh_comments()}

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_params_new(socket) do
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid

    attrs = %{
      lines: [],
      created_by_uuid: user_uuid
    }

    case GoodsReceipts.create_goods_receipt(attrs) do
      {:ok, receipt} ->
        {:noreply,
         push_navigate(socket,
           to: Routes.path("/admin/warehouse/goods-receipts/#{receipt.uuid}")
         )}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("default", "Failed to create draft goods receipt"))
         |> push_navigate(to: Routes.path("/admin/warehouse/goods-receipts"))}
    end
  end

  defp load_receipt_into_socket(socket, uuid) do
    receipt = GoodsReceipts.get_goods_receipt!(uuid)
    same_receipt? = match?(%{uuid: ^uuid}, socket.assigns[:receipt])

    supplier_name = resolve_supplier_name(receipt.supplier_uuid)
    location_name = resolve_location_name(receipt.location_uuid)
    supplier_order_ref = DocRefs.supplier_order_ref(receipt.supplier_order_uuid)

    socket =
      socket
      |> assign(:receipt, receipt)
      |> assign(:supplier_name, supplier_name)
      |> assign(:location_name, location_name)
      |> assign(:supplier_order_ref, supplier_order_ref)
      |> assign(:refs_by_kind, refs_by_kind(receipt))
      |> assign(
        :page_title,
        dgettext("default", "Goods Receipt #%{number}", number: receipt.number)
      )

    socket = if same_receipt?, do: socket, else: assign_edit_buffer(socket, receipt)
    assign_price_proposals(socket)
  end

  defp assign_edit_buffer(socket, receipt) do
    socket
    |> assign(:lines, receipt.lines)
    |> assign(:note, receipt.note || "")
  end

  # Recomputes purchase price proposals from the current receipt state.
  # Only runs for posted receipts with a supplier_uuid — otherwise clears the list.
  # Stateless: derives from live catalogue data on every call; no DB storage.
  defp assign_price_proposals(
         %{assigns: %{receipt: %{status: "posted", supplier_uuid: sup}}} = socket
       )
       when is_binary(sup) do
    proposals =
      CostProposals.derive(
        socket.assigns.lines,
        sup,
        CostProposals.catalogue_resolver()
      )

    assign(socket, :price_proposals, proposals)
  end

  defp assign_price_proposals(socket), do: assign(socket, :price_proposals, [])

  defp maybe_subscribe_and_refresh_comments(socket) do
    receipt = socket.assigns.receipt

    if connected?(socket) and receipt do
      socket =
        if socket.assigns.comments_subscribed? do
          socket
        else
          Comments.subscribe(:goods_receipt, [receipt.uuid])
          assign(socket, :comments_subscribed?, true)
        end

      count = Comments.count(:goods_receipt, receipt.uuid)
      assign(socket, :comment_count, count)
    else
      socket
    end
  end

  defp resolve_supplier_name(nil), do: nil

  defp resolve_supplier_name(supplier_uuid) do
    case Catalogue.get_supplier(supplier_uuid) do
      nil -> nil
      supplier -> supplier.name
    end
  end

  defp resolve_location_name(nil), do: nil

  defp resolve_location_name(location_uuid) do
    case PhoenixKitLocations.Locations.get_location(location_uuid) do
      nil -> nil
      location -> location.name
    end
  end

  # ---------------------------------------------------------------------------
  # File folder resolution
  # ---------------------------------------------------------------------------

  defp maybe_start_files_folder_resolution(socket) do
    cond do
      not is_nil(socket.assigns.files_scope_folder_uuid) ->
        socket

      not connected?(socket) ->
        assign(socket, :files_folder_loading, true)

      true ->
        lv_pid = self()
        receipt = socket.assigns.receipt
        user_uuid = socket.assigns.current_user && socket.assigns.current_user.uuid

        Task.Supervisor.start_child(PhoenixKitWarehouse.TaskSupervisor, fn ->
          result = StorageFolders.ensure_for_goods_receipt(receipt, user_uuid)
          send(lv_pid, {:files_folder_result, result})
        end)

        assign(socket, :files_folder_loading, true)
    end
  end

  # ---------------------------------------------------------------------------
  # Received quantity editing
  # ---------------------------------------------------------------------------

  # MediaBrowser allows the `:media_files` upload on this parent LiveView
  # (see setup_uploads/1), so its `phx-change="validate"` channel fires here.
  # Absorb it to avoid a FunctionClauseError crash on file upload.
  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("set_received_qty", params, socket) do
    index = String.to_integer(params["index"])
    raw = params["received_quantity"] || "0"

    qty = StockLedger.to_decimal(raw) |> clamp_non_negative()

    lines =
      socket.assigns.lines
      |> List.update_at(index, fn line ->
        Map.put(line, "received_quantity", qty)
      end)

    {:noreply, assign(socket, :lines, lines)}
  end

  # ---------------------------------------------------------------------------
  # Receive all ordered (draft only)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("receive_all", _params, %{assigns: %{receipt: %{status: "draft"}}} = socket) do
    lines =
      Enum.map(socket.assigns.lines, fn line ->
        ordered = StockLedger.to_decimal(line["ordered_quantity"] || "0")
        Map.put(line, "received_quantity", ordered)
      end)

    attrs = %{note: socket.assigns.note, lines: lines}
    receipt = socket.assigns.receipt

    case GoodsReceipts.update_draft(receipt, attrs) do
      {:ok, updated_receipt} ->
        {:noreply,
         socket
         |> assign(:receipt, updated_receipt)
         |> assign(:lines, lines)
         |> put_flash(:info, dgettext("default", "All quantities set to ordered"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to update quantities"))}
    end
  end

  def handle_event("receive_all", _params, socket) do
    {:noreply,
     put_flash(socket, :error, dgettext("default", "Cannot modify: document is not a draft"))}
  end

  # ---------------------------------------------------------------------------
  # Source picker — import from supplier order(s)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event(
        "open_source_picker",
        _params,
        %{assigns: %{receipt: %{status: "posted"}}} = socket
      ) do
    {:noreply,
     put_flash(socket, :error, dgettext("default", "Cannot modify: document is not a draft"))}
  end

  def handle_event("open_source_picker", _params, socket) do
    candidates = build_so_candidates()

    socket =
      socket
      |> assign(:picker_purpose, :import)
      |> assign(:show_source_picker, true)
      |> assign(:source_picker_all, candidates)
      |> assign(:source_picker_candidates, candidates)
      |> assign(:source_picker_selected_uuids, [])
      |> assign(:source_picker_selected_meta, %{})
      |> assign(:source_picker_query, "")

    {:noreply, socket}
  end

  @doc false
  # Opens the picker in "manual link" mode — attaches a traceability
  # reference without touching lines/quantities. Unlike "open_source_picker"
  # (line import), this works on both draft and posted receipts.
  @impl true
  def handle_event("open_link_picker", %{"kind" => kind}, socket) do
    {purpose, candidates} =
      case kind do
        "order" -> {:link_order, InternalOrders.list_import_candidates()}
        "internal_order" -> {:link_internal_order, build_io_link_candidates()}
        "supplier_order" -> {:link_supplier_order, build_so_candidates()}
      end

    socket =
      socket
      |> assign(:picker_purpose, purpose)
      |> assign(:show_source_picker, true)
      |> assign(:source_picker_all, candidates)
      |> assign(:source_picker_candidates, candidates)
      |> assign(:source_picker_selected_uuids, [])
      |> assign(:source_picker_selected_meta, %{})
      |> assign(:source_picker_query, "")

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_source_picker", _params, socket) do
    {:noreply, assign(socket, :show_source_picker, false)}
  end

  @impl true
  def handle_event("source_picker_search", %{"query" => query}, socket) do
    all_candidates = socket.assigns.source_picker_all

    filtered =
      if String.trim(query) == "" do
        all_candidates
      else
        q = String.downcase(query)

        Enum.filter(all_candidates, fn c ->
          String.contains?(String.downcase(c.label), q) or
            (c.subtitle && String.contains?(String.downcase(c.subtitle), q))
        end)
      end

    socket =
      socket
      |> assign(:source_picker_candidates, filtered)
      |> assign(:source_picker_query, query)

    {:noreply, socket}
  end

  @impl true
  def handle_event("source_picker_toggle", %{"uuid" => uuid}, socket) do
    selected = socket.assigns.source_picker_selected_uuids
    meta = socket.assigns.source_picker_selected_meta

    {selected, meta} =
      if uuid in selected do
        {List.delete(selected, uuid), Map.delete(meta, uuid)}
      else
        candidate = Enum.find(socket.assigns.source_picker_candidates, &(&1.uuid == uuid))
        type = candidate && Map.get(candidate, :kind)
        {selected ++ [uuid], Map.put(meta, uuid, type)}
      end

    {:noreply,
     socket
     |> assign(:source_picker_selected_uuids, selected)
     |> assign(:source_picker_selected_meta, meta)}
  end

  @impl true
  def handle_event("source_picker_select_all", _params, socket) do
    candidates = socket.assigns.source_picker_candidates
    selected = socket.assigns.source_picker_selected_uuids

    all_selected? = candidates != [] && Enum.all?(candidates, &(&1.uuid in selected))

    {selected, meta} =
      if all_selected? do
        {[], %{}}
      else
        meta = Map.new(candidates, &{&1.uuid, Map.get(&1, :kind)})
        {Enum.uniq(selected ++ Enum.map(candidates, & &1.uuid)), meta}
      end

    {:noreply,
     socket
     |> assign(:source_picker_selected_uuids, selected)
     |> assign(:source_picker_selected_meta, meta)}
  end

  @impl true
  def handle_event(
        "source_picker_confirm",
        _params,
        %{assigns: %{picker_purpose: :import}} = socket
      ) do
    receipt = socket.assigns.receipt
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid
    so_uuids = socket.assigns.source_picker_selected_uuids

    case GoodsReceipts.import_from_supplier_orders(receipt, so_uuids, user_uuid) do
      {:ok, updated_receipt} ->
        socket =
          socket
          |> assign(:receipt, updated_receipt)
          |> assign(:lines, updated_receipt.lines)
          |> assign(:refs_by_kind, refs_by_kind(updated_receipt))
          |> assign(:show_source_picker, false)
          |> assign(:source_picker_selected_uuids, [])
          |> put_flash(:info, dgettext("default", "Lines imported from supplier order(s)"))

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:show_source_picker, false)
         |> put_flash(:error, dgettext("default", "Failed to import lines"))}
    end
  end

  def handle_event("source_picker_confirm", _params, socket) do
    receipt = socket.assigns.receipt
    purpose = socket.assigns.picker_purpose
    selected = socket.assigns.source_picker_selected_uuids
    meta = socket.assigns.source_picker_selected_meta

    result =
      Enum.reduce_while(selected, {:ok, receipt}, fn uuid, {:ok, current_receipt} ->
        type = link_ref_type(purpose, meta, uuid)

        case GoodsReceipts.add_source_ref(current_receipt, type, uuid) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, updated_receipt} ->
        socket =
          socket
          |> assign(:receipt, updated_receipt)
          |> assign(:refs_by_kind, refs_by_kind(updated_receipt))
          |> assign(:show_source_picker, false)
          |> assign(:source_picker_selected_uuids, [])
          |> assign(:source_picker_selected_meta, %{})
          |> put_flash(:info, dgettext("default", "Link added"))

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:show_source_picker, false)
         |> put_flash(:error, dgettext("default", "Failed to add link"))}
    end
  end

  @impl true
  def handle_event("remove_source_ref", %{"type" => type, "uuid" => uuid}, socket) do
    receipt = socket.assigns.receipt

    case GoodsReceipts.remove_source_ref(receipt, type, uuid) do
      {:ok, updated_receipt} ->
        socket =
          socket
          |> assign(:receipt, updated_receipt)
          |> assign(:refs_by_kind, refs_by_kind(updated_receipt))

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to remove link"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Note editing
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("set_note", %{"note" => note}, socket) do
    {:noreply, assign(socket, :note, note)}
  end

  # ---------------------------------------------------------------------------
  # Warehouse (location) selector — draft only
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("set_location", %{"location_uuid" => uuid}, socket) do
    case socket.assigns.receipt do
      %PhoenixKitWarehouse.GoodsReceipt{status: "draft"} = receipt ->
        with {:ok, updated} <- GoodsReceipts.update_draft(receipt, %{location_uuid: uuid}) do
          {:noreply,
           socket
           |> assign(:receipt, updated)
           |> assign(:location_name, resolve_location_name(updated.location_uuid))
           |> put_flash(:info, dgettext("default", "Warehouse changed"))}
        else
          {:error, _changeset} ->
            {:noreply,
             put_flash(socket, :error, dgettext("default", "Failed to change warehouse"))}
        end

      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("default", "Cannot modify: document is not a draft"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Save draft
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_draft", _params, socket) do
    attrs = %{
      note: socket.assigns.note,
      lines: socket.assigns.lines
    }

    case socket.assigns.receipt do
      %PhoenixKitWarehouse.GoodsReceipt{status: "draft"} = receipt ->
        case GoodsReceipts.update_draft(receipt, attrs) do
          {:ok, updated_receipt} ->
            {:noreply,
             socket
             |> assign(:receipt, updated_receipt)
             |> put_flash(:info, dgettext("default", "Draft saved"))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, dgettext("default", "Failed to save draft"))}
        end

      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("default", "Cannot save: document is not a draft"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Post (conduct)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("post", _params, socket) do
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid

    save_attrs = %{
      note: socket.assigns.note,
      lines: socket.assigns.lines
    }

    receipt = socket.assigns.receipt

    with {:ok, saved_receipt} <- ensure_saved(receipt, save_attrs),
         {:ok, _posted_receipt} <- GoodsReceipts.post_goods_receipt(saved_receipt, user_uuid) do
      {:noreply,
       socket
       |> put_flash(:info, dgettext("default", "Goods receipt posted — stock updated"))
       |> push_navigate(to: Routes.path("/admin/warehouse/goods-receipts"))}
    else
      {:error, :not_draft} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Document is already posted"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to post goods receipt"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Save correction (note-only, admin only)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_correction", _params, %{assigns: %{admin?: false}} = socket) do
    {:noreply, put_flash(socket, :error, dgettext("default", "Not authorized"))}
  end

  def handle_event("save_correction", _params, socket) do
    receipt = socket.assigns.receipt
    attrs = %{note: socket.assigns.note}

    case GoodsReceipts.correct_goods_receipt(receipt, attrs) do
      {:ok, corrected_receipt} ->
        {:noreply,
         socket
         |> assign(:receipt, corrected_receipt)
         |> put_flash(:info, dgettext("default", "Correction saved"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to save correction"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Purchase price proposals — update catalogue cost from receipt line
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("update_price", _params, %{assigns: %{admin?: false}} = socket) do
    {:noreply, put_flash(socket, :error, dgettext("default", "Not authorized"))}
  end

  def handle_event("update_price", %{"item_uuid" => item_uuid}, socket) do
    receipt = socket.assigns.receipt
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid
    proposal = Enum.find(socket.assigns.price_proposals, &(&1.item_uuid == item_uuid))

    case proposal do
      nil ->
        {:noreply, socket}

      %{} = p ->
        opts = [
          actor_uuid: user_uuid,
          source: "goods_receipt",
          source_uuid: receipt.uuid
        ]

        case CostProposals.apply_revision(p, opts) do
          {:ok, _info} ->
            {:noreply,
             socket
             |> assign_price_proposals()
             |> put_flash(:info, dgettext("default", "Price updated"))}

          {:error, :catalogue_unavailable} ->
            {:noreply,
             put_flash(socket, :error, dgettext("default", "Catalogue module not available"))}

          {:error, :not_current} ->
            # The catalogue already revised this pair (concurrent editor) —
            # re-derive so the stale proposal disappears instead of wedging
            # every subsequent click.
            {:noreply,
             socket
             |> assign_price_proposals()
             |> put_flash(
               :info,
               dgettext("default", "This price was already revised in the catalogue")
             )}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign_price_proposals()
             |> put_flash(:error, dgettext("default", "Failed to update price"))}
        end
    end
  end

  @impl true
  def handle_event("update_all_prices", _params, %{assigns: %{admin?: false}} = socket) do
    {:noreply, put_flash(socket, :error, dgettext("default", "Not authorized"))}
  end

  def handle_event("update_all_prices", _params, socket) do
    receipt = socket.assigns.receipt
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid
    proposals = socket.assigns.price_proposals

    opts = [
      actor_uuid: user_uuid,
      source: "goods_receipt",
      source_uuid: receipt.uuid
    ]

    # Iterate ALL proposals — one failure must not abort the rest or hide
    # partial success. The card is re-derived afterwards regardless, so
    # applied rows disappear and only genuinely failing pairs remain.
    {ok_count, failed} =
      Enum.reduce(proposals, {0, []}, fn proposal, {ok, failed} ->
        case CostProposals.apply_revision(proposal, opts) do
          {:ok, _info} -> {ok + 1, failed}
          {:error, reason} -> {ok, [{proposal, reason} | failed]}
        end
      end)

    socket = assign_price_proposals(socket)

    socket =
      cond do
        failed == [] ->
          put_flash(socket, :info, dgettext("default", "All prices updated"))

        ok_count > 0 ->
          put_flash(
            socket,
            :error,
            dgettext("default", "Updated %{ok} price(s); %{failed} failed",
              ok: ok_count,
              failed: length(failed)
            )
          )

        true ->
          put_flash(socket, :error, dgettext("default", "Failed to update price"))
      end

    {:noreply, socket}
  end

  # `Map.get(meta, uuid, "order")` alone isn't enough insurance: the key can
  # be present but mapped to `nil` (e.g. an unresolved candidate) rather
  # than absent, and `Map.get/3`'s default only kicks in when the key is
  # missing — so `|| "order"` catches that case too.
  defp link_ref_type(:link_order, meta, uuid), do: Map.get(meta, uuid) || "order"
  defp link_ref_type(:link_internal_order, _meta, _uuid), do: "internal_order"
  defp link_ref_type(:link_supplier_order, _meta, _uuid), do: "supplier_order"

  # ---------------------------------------------------------------------------
  # handle_info
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:files_folder_result, {:ok, folder}}, socket) do
    {:noreply,
     socket
     |> assign(:files_scope_folder_uuid, folder.uuid)
     |> assign(:files_folder_loading, false)}
  end

  def handle_info({:files_folder_result, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:files_folder_loading, false)
     |> put_flash(
       :error,
       dgettext("default", "Could not open files folder: %{reason}", reason: inspect(reason))
     )}
  end

  def handle_info({:comments_updated, _payload}, socket) do
    count =
      case socket.assigns.receipt do
        %{uuid: uuid} when not is_nil(uuid) ->
          Comments.count(:goods_receipt, uuid)

        _ ->
          0
      end

    {:noreply, assign(socket, :comment_count, count)}
  end

  def handle_info({PhoenixKitWeb.Components.MediaBrowser, _action, _payload} = msg, socket) do
    PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:posted?, assigns.receipt && assigns.receipt.status == "posted")
      |> assign(:receipt_uuid, assigns.receipt && assigns.receipt.uuid)

    assigns = assign_new(assigns, :supplier_order_ref, fn -> nil end)

    ~H"""
    <div class="flex flex-col mx-auto max-w-none sm:px-4 py-2 sm:py-6 gap-4">
      <.admin_page_header title={@page_title}>
        <:actions>
          <%!-- Draft: Save draft + Post --%>
          <%= if !@posted? and @active_tab in [:general, :lines] do %>
            <button type="button" phx-click="save_draft" class="btn btn-ghost btn-sm">
              {dgettext("default", "Save draft")}
            </button>
            <button type="button" phx-click="post" class="btn btn-primary btn-sm">
              <.icon name="hero-check" class="w-4 h-4" /> {dgettext("default", "Conduct")}
            </button>
          <% end %>
          <%!-- Posted + admin: correction --%>
          <%= if @posted? and @admin? and @active_tab == :general do %>
            <button type="button" phx-click="save_correction" class="btn btn-ghost btn-sm">
              {dgettext("default", "Save correction")}
            </button>
          <% end %>
          <%!-- Posted badge --%>
          <%= if @posted? do %>
            <span class="badge badge-success badge-lg">{dgettext("default", "Posted")}</span>
          <% end %>
        </:actions>
      </.admin_page_header>

      <%!-- Tab navigation --%>
      <div class="tabs tabs-border">
        <.link
          patch={Routes.path("/admin/warehouse/goods-receipts/#{@receipt_uuid}")}
          class={["tab", @active_tab == :general && "tab-active"]}
        >
          {dgettext("default", "General")}
        </.link>
        <.link
          :if={@receipt_uuid}
          patch={Routes.path("/admin/warehouse/goods-receipts/#{@receipt_uuid}/lines")}
          class={["tab", @active_tab == :lines && "tab-active"]}
        >
          {dgettext("default", "Lines")}
        </.link>
        <.link
          :if={@receipt_uuid}
          patch={Routes.path("/admin/warehouse/goods-receipts/#{@receipt_uuid}/files")}
          class={["tab", @active_tab == :files && "tab-active"]}
        >
          {dgettext("default", "Files")}
        </.link>
        <.link
          :if={@receipt_uuid}
          patch={Routes.path("/admin/warehouse/goods-receipts/#{@receipt_uuid}/comments")}
          class={["tab", @active_tab == :comments && "tab-active"]}
        >
          {dgettext("default", "Comments")}
          <span :if={@comment_count > 0} class="badge badge-sm badge-ghost ml-1">
            {@comment_count}
          </span>
        </.link>
      </div>

      <%!-- Posted banner (non-admin) --%>
      <%= if @posted? and not @admin? do %>
        <div class="alert alert-success">
          <.icon name="hero-check-circle" class="w-5 h-5" />
          <span>{dgettext("default", "This goods receipt has been posted and stock has been updated.")}</span>
        </div>
      <% end %>

      <%!-- Tab: General --%>
      <%= if @active_tab == :general do %>
        <%= if !@posted? do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4">
              <form phx-change="set_note" phx-submit="set_note">
                <input
                  type="text"
                  id="gr-note-input"
                  name="note"
                  value={@note}
                  placeholder={dgettext("default", "Note (optional)")}
                  class="input input-sm w-full max-w-lg"
                  phx-debounce="500"
                  phx-hook="InvEnterBlur"
                />
              </form>
            </div>
          </div>
        <% end %>

        <%= if @receipt do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4">
              <dl class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-sm">
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Number")}</dt>
                  <dd class="mt-0.5 font-mono">#GR-{@receipt.number}</dd>
                </div>
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Status")}</dt>
                  <dd class="mt-0.5">
                    <span class={[
                      "badge badge-sm",
                      @receipt.status == "posted" && "badge-success",
                      @receipt.status == "draft" && "badge-warning"
                    ]}>
                      {@receipt.status}
                    </span>
                  </dd>
                </div>
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Supplier")}</dt>
                  <dd class="mt-0.5">
                    <%= if @supplier_name do %>
                      {@supplier_name}
                    <% else %>
                      <span class="text-base-content/40">{dgettext("default", "— not set —")}</span>
                    <% end %>
                  </dd>
                </div>
                <div>
                  <dt class="text-base-content/60 font-medium">
                    {dgettext("default", "Warehouse (location)")}
                  </dt>
                  <dd class="mt-0.5">
                    <%= if !@posted? and warehouse_options?(@warehouses) do %>
                      <form phx-change="set_location" phx-submit="set_location">
                        <select name="location_uuid" class="select select-sm select-bordered">
                          <%= for warehouse <- @warehouses do %>
                            <option
                              value={warehouse.uuid}
                              selected={@receipt.location_uuid == warehouse.uuid}
                            >
                              {warehouse.name}
                            </option>
                          <% end %>
                        </select>
                      </form>
                    <% else %>
                      <%= if @location_name do %>
                        {@location_name}
                      <% else %>
                        <span class="text-base-content/40">{dgettext("default", "— not set —")}</span>
                      <% end %>
                    <% end %>
                  </dd>
                </div>
                <%= if @supplier_order_ref do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Supplier Order")}
                    </dt>
                    <dd class="mt-0.5">
                      <.link
                        navigate={@supplier_order_ref.path}
                        class="link link-primary font-mono text-sm"
                      >
                        {@supplier_order_ref.label}
                      </.link>
                    </dd>
                  </div>
                <% end %>
                <.ref_group
                  title={dgettext("default", "Customer orders")}
                  refs={(@refs_by_kind[:order] || []) ++ (@refs_by_kind[:sub_order] || [])}
                  link_kind="order"
                />
                <.ref_group
                  title={dgettext("default", "Supplier orders")}
                  refs={@refs_by_kind[:supplier_order] || []}
                  link_kind="supplier_order"
                />
                <.ref_group
                  title={dgettext("default", "Internal orders")}
                  refs={@refs_by_kind[:internal_order] || []}
                  link_kind="internal_order"
                />
                <%= if @receipt.inserted_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Created")}
                    </dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@receipt.inserted_at, "%Y-%m-%d %H:%M")}
                    </dd>
                  </div>
                <% end %>
                <%= if @receipt.posted_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">{dgettext("default", "Posted at")}</dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@receipt.posted_at, "%Y-%m-%d %H:%M")}
                    </dd>
                  </div>
                <% end %>
                <%= if @receipt.note && @posted? do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Note")}
                    </dt>
                    <dd class="mt-0.5">{@receipt.note}</dd>
                  </div>
                <% end %>
              </dl>
              <%!-- Note edit on posted (admin only) --%>
              <%= if @posted? and @admin? do %>
                <div class="divider my-1"></div>
                <div class="text-sm">
                  <label class="text-base-content/60 font-medium block mb-1">
                    {dgettext("default", "Note")}
                  </label>
                  <form phx-change="set_note" phx-submit="set_note">
                    <input
                      type="text"
                      id="gr-note-posted-input"
                      name="note"
                      value={@note}
                      placeholder={dgettext("default", "Note (optional)")}
                      class="input input-sm w-full max-w-lg"
                      phx-debounce="500"
                      phx-hook="InvEnterBlur"
                    />
                  </form>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>

      <%!-- Tab: Lines --%>
      <%= if @active_tab == :lines do %>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-center justify-between gap-2 mb-2">
              <h2 class="card-title text-base">{dgettext("default", "Receipt Lines")}</h2>
              <%= if !@posted? do %>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    phx-click="open_source_picker"
                    class="btn btn-outline btn-sm"
                  >
                    <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
                    {dgettext("default", "Import from supplier order")}
                  </button>
                  <button
                    type="button"
                    phx-click="receive_all"
                    class="btn btn-outline btn-sm"
                  >
                    {dgettext("default", "Receive all ordered")}
                  </button>
                </div>
              <% end %>
            </div>
            <%= if @posted? do %>
              <div class="alert alert-info mb-2">
                <.icon name="hero-information-circle" class="w-5 h-5" />
                <span>{dgettext("default", "Lines are read-only on a posted goods receipt.")}</span>
              </div>
            <% end %>
            <.goods_receipt_lines_table lines={@lines} posted?={@posted?} />
          </div>
        </div>
        <%!-- Purchase price proposals card (posted receipts with a supplier only) --%>
        <%= if @posted? and @price_proposals != [] do %>
          <.price_proposals_card
            proposals={@price_proposals}
            admin?={@admin?}
          />
        <% end %>
      <% end %>

      <%!-- Tab: Files --%>
      <%= if @active_tab == :files do %>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body p-4">
            <%= cond do %>
              <% @files_folder_loading -> %>
                <div class="flex justify-center p-8">
                  <span class="loading loading-spinner loading-md" />
                  <span class="ml-2">{dgettext("default", "Loading files...")}</span>
                </div>
              <% is_nil(@files_scope_folder_uuid) -> %>
                <div class="alert alert-warning">
                  {dgettext("default", "Files are not available for this goods receipt yet.")}
                </div>
              <% true -> %>
                <.live_component
                  module={PhoenixKitWeb.Components.MediaBrowser}
                  id={"media-browser-gr-#{@receipt_uuid}"}
                  scope_folder_id={@files_scope_folder_uuid}
                  parent_uploads={@uploads}
                  phoenix_kit_current_user={@current_user}
                />
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Tab: Comments --%>
      <%= if @active_tab == :comments do %>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body p-4">
            <%= if @comments_available? do %>
              <CommentsPanel.panel
                kind={:goods_receipt}
                resource_uuid={@receipt_uuid}
                current_user={@current_user}
                title={dgettext("default", "Comments")}
              />
            <% else %>
              <div class="alert alert-warning">
                {dgettext(
                  "default",
                  "Comments module is disabled. Enable it in PhoenixKit settings."
                )}
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Source picker modal: import lines from supplier orders, or attach a manual link --%>
      <WarehouseBrowser.source_picker
        id="gr-source-picker"
        show={@show_source_picker}
        title={picker_title(@picker_purpose)}
        on_close="close_source_picker"
        candidates={@source_picker_candidates}
        selected_uuids={@source_picker_selected_uuids}
        search_query={@source_picker_query}
      />
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:refs, :list, required: true)
  attr(:link_kind, :string, required: true)

  defp ref_group(assigns) do
    ~H"""
    <div class="sm:col-span-2">
      <dt class="text-base-content/60 font-medium flex items-center gap-1">
        {@title}
        <button
          type="button"
          phx-click="open_link_picker"
          phx-value-kind={@link_kind}
          class="btn btn-2xs btn-ghost btn-circle"
          title={dgettext("default", "Attach")}
        >
          <.icon name="hero-plus" class="w-3 h-3" />
        </button>
      </dt>
      <dd class="mt-0.5 flex flex-wrap gap-2">
        <span :if={@refs == []} class="text-base-content/30 text-sm">—</span>
        <%= for ref <- @refs do %>
          <span class="inline-flex items-center gap-1 bg-base-200 rounded px-2 py-0.5">
            <.link navigate={ref.path} class="link link-primary font-mono text-sm">
              {ref.label}
            </.link>
            <button
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
      </dd>
    </div>
    """
  end

  defp picker_title(:import), do: dgettext("default", "Import from supplier order")
  defp picker_title(:link_order), do: dgettext("default", "Attach customer order")
  defp picker_title(:link_internal_order), do: dgettext("default", "Attach internal order")
  defp picker_title(:link_supplier_order), do: dgettext("default", "Attach supplier order")

  # ---------------------------------------------------------------------------
  # Function component: lines verification table
  # ---------------------------------------------------------------------------

  attr(:lines, :list, required: true)
  attr(:posted?, :boolean, required: true)

  defp goods_receipt_lines_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>{dgettext("default", "Item")}</th>
            <th class="w-16 text-center">{dgettext("default", "Unit")}</th>
            <th class="w-28 text-right">{dgettext("default", "Ordered")}</th>
            <th class="w-28 text-right">{dgettext("default", "Received")}</th>
            <th class="w-28 text-center">{dgettext("default", "Δ")}</th>
            <th class="w-28 text-right">{dgettext("default", "Prior stock")}</th>
          </tr>
        </thead>
        <tbody>
          <%= if @lines == [] do %>
            <tr>
              <td colspan="6" class="text-center text-base-content/50 py-4">
                {dgettext("default", "No lines yet")}
              </td>
            </tr>
          <% end %>
          <%= for {line, index} <- Enum.with_index(@lines) do %>
            <% ordered = StockLedger.to_decimal(line["ordered_quantity"] || "0") %>
            <% received = StockLedger.to_decimal(line["received_quantity"] || "0") %>
            <% diff = Decimal.sub(received, ordered) %>
            <tr class="hover">
              <td>
                <div class="font-medium">{line["name"] || "—"}</div>
                <div :if={line["sku"]} class="text-xs text-base-content/50 font-mono">
                  {line["sku"]}
                </div>
              </td>
              <td class="text-center text-xs text-base-content/60">
                {WarehouseBrowser.unit_label(line["unit"])}
              </td>
              <td class="text-right tabular-nums text-sm text-base-content/60">
                {fmt_qty(line["ordered_quantity"])}
              </td>
              <td class="text-right">
                <%= if @posted? do %>
                  <span class="tabular-nums text-sm">{fmt_qty(line["received_quantity"])}</span>
                <% else %>
                  <form
                    id={"gr-rcv-form-#{index}"}
                    phx-change="set_received_qty"
                    phx-submit="set_received_qty"
                  >
                    <input type="hidden" name="index" value={index} />
                    <input
                      type="number"
                      id={"gr-rcv-#{index}"}
                      name="received_quantity"
                      min="0"
                      step="any"
                      value={fmt_qty(line["received_quantity"])}
                      placeholder="0"
                      class="input input-sm w-24 text-right tabular-nums"
                      phx-debounce="blur"
                      phx-hook="InvEnterBlur"
                    />
                  </form>
                <% end %>
              </td>
              <td class="text-center">
                <%= cond do %>
                  <% Decimal.equal?(diff, Decimal.new("0")) -> %>
                    <span class="text-base-content/40 text-sm">✓</span>
                  <% Decimal.compare(diff, Decimal.new("0")) == :lt -> %>
                    <span class="badge badge-warning badge-sm">
                      {dgettext("default", "short %{n}",
                        n: Decimal.to_string(Decimal.abs(diff), :normal)
                      )}
                    </span>
                  <% true -> %>
                    <span class="badge badge-info badge-sm">
                      {dgettext("default", "over %{n}", n: Decimal.to_string(diff, :normal))}
                    </span>
                <% end %>
              </td>
              <td class="text-right tabular-nums text-sm text-base-content/40">
                {fmt_qty(line["previous_quantity"])}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Function component: purchase price proposals card
  # ---------------------------------------------------------------------------

  attr(:proposals, :list, required: true)
  attr(:admin?, :boolean, required: true)

  defp price_proposals_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-warning/40">
      <div class="card-body p-4">
        <div class="flex items-center justify-between gap-2 mb-3">
          <h2 class="card-title text-base text-warning">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
            {dgettext("default", "Purchase price proposals")}
          </h2>
          <%= if @admin? and length(@proposals) > 1 do %>
            <button
              type="button"
              phx-click="update_all_prices"
              class="btn btn-warning btn-sm"
            >
              {dgettext("default", "Update all")}
            </button>
          <% end %>
        </div>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>{dgettext("default", "Item")}</th>
                <th>{dgettext("default", "Supplier")}</th>
                <th class="text-right">{dgettext("default", "Current cost")}</th>
                <th class="text-right">{dgettext("default", "Receipt price")}</th>
                <%= if @admin? do %>
                  <th></th>
                <% end %>
              </tr>
            </thead>
            <tbody>
              <%= for proposal <- @proposals do %>
                <tr class="hover">
                  <td>
                    <div class="font-medium">{proposal.name || "—"}</div>
                    <div :if={proposal.sku} class="text-xs text-base-content/50 font-mono">
                      {proposal.sku}
                    </div>
                  </td>
                  <td class="text-sm text-base-content/70">
                    {proposal.info.supplier_name_snapshot || "—"}
                  </td>
                  <td class="text-right tabular-nums text-sm">
                    <%= if proposal.current_cost do %>
                      {Decimal.to_string(proposal.current_cost, :normal)}
                      <span :if={proposal.info.currency} class="text-xs text-base-content/50">
                        {proposal.info.currency}
                      </span>
                    <% else %>
                      <span class="text-base-content/40">—</span>
                    <% end %>
                  </td>
                  <td class="text-right tabular-nums text-sm font-medium">
                    {Decimal.to_string(proposal.receipt_price, :normal)}
                    <span :if={proposal.info.currency} class="text-xs text-base-content/50">
                      {proposal.info.currency}
                    </span>
                  </td>
                  <%= if @admin? do %>
                    <td>
                      <button
                        type="button"
                        phx-click="update_price"
                        phx-value-item_uuid={proposal.item_uuid}
                        class="btn btn-xs btn-warning"
                      >
                        {dgettext("default", "Update price")}
                      </button>
                    </td>
                  <% end %>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp ensure_saved(%PhoenixKitWarehouse.GoodsReceipt{status: "draft"} = receipt, attrs) do
    GoodsReceipts.update_draft(receipt, attrs)
  end

  defp ensure_saved(%PhoenixKitWarehouse.GoodsReceipt{} = receipt, _attrs) do
    {:ok, receipt}
  end

  defp clamp_non_negative(%Decimal{} = d) do
    zero = Decimal.new("0")
    if Decimal.compare(d, zero) == :lt, do: zero, else: d
  end

  defp fmt_qty(nil), do: "0"
  defp fmt_qty(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp fmt_qty(v), do: to_string(v)

  # `list_warehouses/0` returns nil when the warehouse LocationType isn't
  # configured yet, or [] when configured but empty — neither is selectable.
  defp warehouse_options?(nil), do: false
  defp warehouse_options?([]), do: false
  defp warehouse_options?(_), do: true

  # Builds source picker candidates from posted supplier orders.
  defp build_so_candidates do
    SupplierOrders.list_posted_supplier_orders()
    |> Enum.map(fn so ->
      supplier_name = resolve_supplier_name(so.supplier_uuid)

      %{
        uuid: so.uuid,
        label: "#SO-#{so.number}",
        subtitle: supplier_name,
        badge: so.status
      }
    end)
  end

  # Builds "attach a link" candidates from posted internal orders.
  defp build_io_link_candidates do
    SupplierOrders.list_posted_internal_orders()
    |> Enum.map(fn io ->
      %{uuid: io.uuid, label: "#IO-#{io.number}", subtitle: io.note, badge: io.status}
    end)
  end

  # Groups a receipt's resolved source_refs by tier for the grouped display.
  defp refs_by_kind(receipt) do
    (receipt.source_refs || [])
    |> DocRefs.refs_for()
    |> Enum.group_by(& &1.kind)
  end
end
