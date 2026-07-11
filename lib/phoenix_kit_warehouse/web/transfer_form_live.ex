defmodule PhoenixKitWarehouse.Web.TransferFormLive do
  @moduledoc """
  LiveView for creating and editing transfers (stock moved between two
  warehouses).

  Handles:
  - `:new`      — creates a draft (no locations, no lines) and push_navigate
                  to :edit path. Immediate-draft pattern, like Internal Orders.
  - `:edit`     — loads an existing transfer; :general tab.
  - `:items`    — lines editor (transfer_quantity editable in draft only —
                  once shipped the goods have physically left, so lines
                  become read-only).
  - `:files`    — MediaBrowser; storage folder resolved asynchronously.
  - `:comments` — transfer comments thread.

  Status lifecycle: `draft -> in_transit -> done`, with a side `cancelled`
  status reachable from `draft` (no stock postings) or `in_transit` (reverses
  the ship posting, crediting stock back to the source). See
  `PhoenixKitWarehouse.Transfers` for the posting mechanics.

  Structurally a copy of `InternalOrderFormLive` (admin-chrome pattern:
  `use PhoenixKitWeb, :live_view` + `<.admin_page_header>`, no self-wrap, no
  streams), with two differences of substance:
  - Two `<select>`s (source/destination warehouse) instead of one, editable
    only while `status == "draft"`.
  - No "import lines from a source" flow — a transfer has no natural upstream
    document to pull required quantities from, so lines only ever come from
    the catalogue "Add item" picker. The upstream `source_refs` traceability
    link (via `PhoenixKitWarehouse.SourceKinds`) is still manual-link-only,
    reusing the same picker component in its "link" mode.

  All navigation paths wrapped in `PhoenixKit.Utils.Routes.path/1`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWarehouse.Gettext
  use PhoenixKitComments.Embed

  alias PhoenixKitWarehouse.ActivityLog
  alias PhoenixKitWarehouse.Comments
  alias PhoenixKitWarehouse.DocRefs
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.StorageFolders
  alias PhoenixKitWarehouse.Transfer
  alias PhoenixKitWarehouse.Transfers
  alias PhoenixKitWarehouse.Web.Components.{CommentsPanel, RelatedDocuments, WarehouseBrowser}
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitLocations.Locations

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    locale = socket.assigns[:current_locale] || Gettext.get_locale()

    scope = socket.assigns[:phoenix_kit_current_scope]
    current_user = scope && PhoenixKit.Users.Auth.Scope.user(scope)
    admin? = !!(scope && PhoenixKit.Users.Auth.Scope.admin?(scope))

    comments_available? = Comments.available?()

    socket =
      socket
      |> assign(:locale, locale)
      |> assign(:current_user, current_user)
      |> assign(:admin?, admin?)
      |> assign(:show_add_picker_modal, false)
      |> assign(:transfer, nil)
      |> assign(:lines, [])
      |> assign(:note, "")
      |> assign(:names, %{})
      |> assign(:active_tab, :general)
      |> assign(:files_scope_folder_uuid, nil)
      |> assign(:files_folder_loading, false)
      |> assign(:comments_available?, comments_available?)
      |> assign(:comment_count, 0)
      |> assign(:comments_subscribed?, false)
      |> assign(:source_location_name, nil)
      |> assign(:destination_location_name, nil)
      |> assign(:warehouses, StockLedger.list_warehouses())
      |> assign(:source_refs, [])
      |> assign(:show_cancel_confirm_modal, false)
      |> assign(:page_title, dgettext("default", "Transfer"))
      |> assign(:catalogue_summaries, [])
      |> assign(:expanded_catalogues, MapSet.new())
      |> assign(:expanded_categories, MapSet.new())
      |> assign(:loaded_categories, %{})
      |> assign(:loaded_items, %{})
      |> assign(:item_search_query, "")
      |> assign(:item_search_results, nil)
      |> assign(:add_mode, :one)
      |> assign(:search_mode, :list)
      |> assign(:show_source_picker, false)
      |> assign(:source_picker_candidates, [])
      |> assign(:source_picker_selected, MapSet.new())
      |> assign(:source_picker_selected_meta, %{})
      |> assign(:source_picker_query, "")
      |> PhoenixKitWeb.Components.MediaBrowser.setup_uploads()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    locale = socket.assigns.locale
    action = socket.assigns.live_action

    socket =
      if socket.assigns.catalogue_summaries == [] do
        catalogue_summaries =
          load_catalogue_summaries(Catalogue.list_catalogues(status: "active"))

        assign(socket, :catalogue_summaries, catalogue_summaries)
      else
        socket
      end

    case action do
      :new ->
        handle_params_new(socket)

      :edit ->
        uuid = params["uuid"]
        socket = load_transfer_into_socket(socket, uuid, locale)

        {:noreply,
         socket |> assign(:active_tab, :general) |> maybe_subscribe_and_refresh_comments()}

      :items ->
        uuid = params["uuid"]
        socket = load_transfer_into_socket(socket, uuid, locale)

        {:noreply,
         socket |> assign(:active_tab, :items) |> maybe_subscribe_and_refresh_comments()}

      :files ->
        uuid = params["uuid"]
        socket = load_transfer_into_socket(socket, uuid, locale)

        {:noreply,
         socket
         |> assign(:active_tab, :files)
         |> maybe_start_files_folder_resolution()
         |> maybe_subscribe_and_refresh_comments()}

      :comments ->
        uuid = params["uuid"]
        socket = load_transfer_into_socket(socket, uuid, locale)

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

    attrs = %{lines: [], created_by_uuid: user_uuid}

    case Transfers.create_transfer(attrs) do
      {:ok, transfer} ->
        {:noreply,
         push_navigate(socket, to: Routes.path("/admin/warehouse/transfers/#{transfer.uuid}"))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("default", "Failed to create draft transfer"))
         |> push_navigate(to: Routes.path("/admin/warehouse/transfers"))}
    end
  end

  defp load_transfer_into_socket(socket, uuid, locale) do
    transfer = Transfers.get_transfer!(uuid)
    same_transfer? = match?(%{uuid: ^uuid}, socket.assigns[:transfer])

    source_refs = DocRefs.refs_for(transfer.source_refs || [])

    socket =
      socket
      |> assign(:transfer, transfer)
      |> assign(:source_location_name, resolve_location_name(transfer.source_location_uuid))
      |> assign(
        :destination_location_name,
        resolve_location_name(transfer.destination_location_uuid)
      )
      |> assign(:source_refs, source_refs)
      |> assign(
        :page_title,
        dgettext("default", "Transfer #%{number}", number: transfer.number)
      )

    if same_transfer?, do: socket, else: assign_edit_buffer(socket, transfer, locale)
  end

  defp assign_edit_buffer(socket, transfer, locale) do
    socket
    |> assign(:lines, transfer.lines)
    |> assign(:note, transfer.note || "")
    |> assign(:names, build_names_map(transfer.lines, locale))
  end

  defp resolve_location_name(nil), do: nil

  defp resolve_location_name(location_uuid) do
    case Locations.get_location(location_uuid) do
      nil -> nil
      location -> location.name
    end
  end

  # ---------------------------------------------------------------------------
  # MediaBrowser validate absorber
  # ---------------------------------------------------------------------------

  # MediaBrowser allows the `:media_files` upload on this parent LiveView
  # (see setup_uploads/1), so its `phx-change="validate"` channel fires here.
  # Absorb it to avoid a FunctionClauseError crash on file upload.
  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Add picker modal handlers (catalogue "Add item")
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("open_add_picker", _params, socket) do
    socket =
      socket
      |> assign(:show_add_picker_modal, true)
      |> assign(:item_search_query, "")
      |> assign(:item_search_results, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_add_picker", _params, socket) do
    {:noreply, assign(socket, :show_add_picker_modal, false)}
  end

  # ---------------------------------------------------------------------------
  # Source picker modal handlers — manual "link" mode only (no line import)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("open_link_picker", _params, socket) do
    candidates = InternalOrders.list_import_candidates()

    socket =
      socket
      |> assign(:show_source_picker, true)
      |> assign(:source_picker_candidates, candidates)
      |> assign(:source_picker_selected, MapSet.new())
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
    candidates = InternalOrders.list_import_candidates(query)

    {:noreply,
     socket
     |> assign(:source_picker_candidates, candidates)
     |> assign(:source_picker_query, query)}
  end

  @impl true
  def handle_event("source_picker_toggle", %{"uuid" => uuid}, socket) do
    selected = socket.assigns.source_picker_selected
    meta = socket.assigns.source_picker_selected_meta

    {selected, meta} =
      if MapSet.member?(selected, uuid) do
        {MapSet.delete(selected, uuid), Map.delete(meta, uuid)}
      else
        candidate = Enum.find(socket.assigns.source_picker_candidates, &(&1.uuid == uuid))
        type = candidate && candidate.kind
        {MapSet.put(selected, uuid), Map.put(meta, uuid, type)}
      end

    {:noreply,
     socket
     |> assign(:source_picker_selected, selected)
     |> assign(:source_picker_selected_meta, meta)}
  end

  @impl true
  def handle_event("source_picker_select_all", _params, socket) do
    candidates = socket.assigns.source_picker_candidates
    selected = socket.assigns.source_picker_selected

    all_selected? =
      candidates != [] && Enum.all?(candidates, &MapSet.member?(selected, &1.uuid))

    {selected, meta} =
      if all_selected? do
        {MapSet.new(), %{}}
      else
        Enum.reduce(candidates, {selected, socket.assigns.source_picker_selected_meta}, fn c,
                                                                                           {sel,
                                                                                            m} ->
          {MapSet.put(sel, c.uuid), Map.put(m, c.uuid, c.kind)}
        end)
      end

    {:noreply,
     socket
     |> assign(:source_picker_selected, selected)
     |> assign(:source_picker_selected_meta, meta)}
  end

  @impl true
  def handle_event("source_picker_confirm", _params, socket) do
    transfer = socket.assigns.transfer
    meta = socket.assigns.source_picker_selected_meta

    result =
      Enum.reduce_while(meta, {:ok, transfer}, fn {uuid, type}, {:ok, current_transfer} ->
        case Transfers.add_source_ref(current_transfer, type, uuid) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, updated_transfer} ->
        source_refs = DocRefs.refs_for(updated_transfer.source_refs || [])

        socket =
          socket
          |> assign(:transfer, updated_transfer)
          |> assign(:source_refs, source_refs)
          |> assign(:show_source_picker, false)
          |> assign(:source_picker_selected, MapSet.new())
          |> assign(:source_picker_selected_meta, %{})
          |> assign(:source_picker_query, "")
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
    transfer = socket.assigns.transfer

    case Transfers.remove_source_ref(transfer, type, uuid) do
      {:ok, updated_transfer} ->
        socket =
          socket
          |> assign(:transfer, updated_transfer)
          |> assign(:source_refs, DocRefs.refs_for(updated_transfer.source_refs || []))

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to remove link"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Add-item picker: mode toggles + catalogue tree navigation + search
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("set_add_mode", %{"mode" => mode}, socket) do
    add_mode = if mode == "many", do: :many, else: :one
    {:noreply, assign(socket, :add_mode, add_mode)}
  end

  @impl true
  def handle_event("set_search_mode", %{"mode" => mode}, socket) do
    search_mode = if mode == "tree", do: :tree, else: :list
    {:noreply, assign(socket, :search_mode, search_mode)}
  end

  @impl true
  def handle_event("toggle_catalogue", %{"uuid" => uuid}, socket) do
    socket = ensure_catalogue_categories_loaded(socket, uuid)

    expanded =
      if MapSet.member?(socket.assigns.expanded_catalogues, uuid) do
        MapSet.delete(socket.assigns.expanded_catalogues, uuid)
      else
        MapSet.put(socket.assigns.expanded_catalogues, uuid)
      end

    {:noreply, assign(socket, :expanded_catalogues, expanded)}
  end

  @impl true
  def handle_event("toggle_category", %{"catalogue_uuid" => cat_uuid, "key" => key}, socket) do
    socket = ensure_category_items_loaded(socket, cat_uuid, key)

    tuple = {cat_uuid, key}

    expanded =
      if MapSet.member?(socket.assigns.expanded_categories, tuple) do
        MapSet.delete(socket.assigns.expanded_categories, tuple)
      else
        MapSet.put(socket.assigns.expanded_categories, tuple)
      end

    {:noreply, assign(socket, :expanded_categories, expanded)}
  end

  @impl true
  def handle_event("picker_search", %{"query" => query}, socket) when byte_size(query) < 2 do
    {:noreply,
     socket
     |> assign(:item_search_query, query)
     |> assign(:item_search_results, nil)}
  end

  def handle_event("picker_search", %{"query" => query}, socket) do
    results = Catalogue.search_items(query, limit: 50)

    {:noreply,
     socket
     |> assign(:item_search_query, query)
     |> assign(:item_search_results, results)}
  end

  @impl true
  def handle_event("picker_search_clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:item_search_query, "")
     |> assign(:item_search_results, nil)}
  end

  @impl true
  def handle_event("add_position", %{"item_uuid" => item_uuid}, socket) do
    editable? = socket.assigns.transfer && socket.assigns.transfer.status == "draft"

    socket =
      if editable? do
        socket = add_item_to_lines(socket, item_uuid)

        case socket.assigns.add_mode do
          :one ->
            index = Enum.find_index(socket.assigns.lines, &(&1["item_uuid"] == item_uuid))

            socket
            |> assign(:show_add_picker_modal, false)
            |> focus_qty_input(index)

          :many ->
            socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Line editing events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("remove_line", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    lines = List.delete_at(socket.assigns.lines, index)
    {:noreply, assign(socket, :lines, lines)}
  end

  @impl true
  def handle_event("set_transfer_qty", params, socket) do
    index = String.to_integer(params["index"])
    raw = params["transfer_quantity"] || "0"

    lines =
      socket.assigns.lines
      |> List.update_at(index, fn line ->
        Map.put(line, "transfer_quantity", raw)
      end)

    {:noreply, assign(socket, :lines, lines)}
  end

  @impl true
  def handle_event("set_note", %{"note" => note}, socket) do
    {:noreply, assign(socket, :note, note)}
  end

  # ---------------------------------------------------------------------------
  # Warehouse selectors — draft only
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("set_source_location", %{"location_uuid" => uuid}, socket) do
    update_location(socket, :source_location_uuid, uuid)
  end

  @impl true
  def handle_event("set_destination_location", %{"location_uuid" => uuid}, socket) do
    update_location(socket, :destination_location_uuid, uuid)
  end

  # ---------------------------------------------------------------------------
  # Save draft
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_draft", _params, socket) do
    attrs = %{note: socket.assigns.note, lines: socket.assigns.lines}

    case socket.assigns.transfer do
      %Transfer{status: "draft"} = transfer ->
        case Transfers.update_draft(transfer, attrs) do
          {:ok, updated_transfer} ->
            {:noreply,
             socket
             |> assign(:transfer, updated_transfer)
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
  # Ship (draft -> in_transit) — DECREASES stock at the source
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("ship", _params, socket) do
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid

    save_attrs = %{note: socket.assigns.note, lines: socket.assigns.lines}
    transfer = socket.assigns.transfer

    with {:ok, saved_transfer} <- ensure_saved(transfer, save_attrs),
         {:ok, _shipped_transfer} <- Transfers.ship_transfer(saved_transfer, user_uuid) do
      {:noreply,
       socket
       |> put_flash(:info, dgettext("default", "Transfer shipped — stock updated at source"))
       |> push_navigate(to: Routes.path("/admin/warehouse/transfers"))}
    else
      {:error, :not_draft} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Document is already shipped"))}

      {:error, :locations_required} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext(
             "default",
             "Please select two different warehouses before shipping"
           )
         )}

      {:error, {:insufficient_stock, item_uuid}} ->
        line = Enum.find(socket.assigns.lines, &(&1["item_uuid"] == item_uuid))
        item_name = (line && line["name"]) || item_uuid

        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext(
             "default",
             "Insufficient stock for: %{item}. Reduce quantity or check stock levels.",
             item: item_name
           )
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to ship transfer"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Receive (in_transit -> done) — INCREASES stock at the destination
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("receive", _params, socket) do
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid
    transfer = socket.assigns.transfer

    case Transfers.receive_transfer(transfer, user_uuid) do
      {:ok, _received_transfer} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext("default", "Transfer received — stock updated at destination")
         )
         |> push_navigate(to: Routes.path("/admin/warehouse/transfers"))}

      {:error, :not_in_transit} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Document is not in transit"))}

      {:error, :locations_required} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("default", "Both warehouses must be set before receiving")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to receive transfer"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Cancel — from draft (no postings) or in_transit (reverses the ship
  # posting). The in_transit path is gated behind a confirmation modal since
  # it reverses stock that has already moved; draft cancellation fires
  # directly since nothing has moved yet.
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("open_cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :show_cancel_confirm_modal, true)}
  end

  @impl true
  def handle_event("close_cancel_confirm", _params, socket) do
    {:noreply, assign(socket, :show_cancel_confirm_modal, false)}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid
    transfer = socket.assigns.transfer

    case Transfers.cancel_transfer(transfer, user_uuid) do
      {:ok, cancelled_transfer} ->
        ActivityLog.log_transfer_cancelled(cancelled_transfer, actor: current_user)

        {:noreply,
         socket
         |> assign(:show_cancel_confirm_modal, false)
         |> put_flash(:info, dgettext("default", "Transfer cancelled"))
         |> push_navigate(to: Routes.path("/admin/warehouse/transfers"))}

      {:error, :not_cancellable} ->
        {:noreply,
         socket
         |> assign(:show_cancel_confirm_modal, false)
         |> put_flash(:error, dgettext("default", "This transfer can no longer be cancelled"))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:show_cancel_confirm_modal, false)
         |> put_flash(:error, dgettext("default", "Failed to cancel transfer"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Save correction (note-only, admin-only, done/cancelled only)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_correction", _params, %{assigns: %{admin?: false}} = socket) do
    {:noreply, put_flash(socket, :error, dgettext("default", "Not authorized"))}
  end

  def handle_event("save_correction", _params, socket) do
    transfer = socket.assigns.transfer
    attrs = %{note: socket.assigns.note}

    case Transfers.correct_transfer(transfer, attrs) do
      {:ok, corrected_transfer} ->
        {:noreply,
         socket
         |> assign(:transfer, corrected_transfer)
         |> put_flash(:info, dgettext("default", "Correction saved"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to save correction"))}
    end
  end

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
      case socket.assigns.transfer do
        %{uuid: uuid} when not is_nil(uuid) ->
          Comments.count(:transfer, uuid)

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
      |> assign(:draft?, assigns.transfer && assigns.transfer.status == "draft")
      |> assign(:in_transit?, assigns.transfer && assigns.transfer.status == "in_transit")
      |> assign(
        :terminal?,
        assigns.transfer && assigns.transfer.status in ["done", "cancelled"]
      )
      |> assign(
        :editable_locations?,
        assigns.transfer && assigns.transfer.status == "draft"
      )
      |> assign(:transfer_uuid, assigns.transfer && assigns.transfer.uuid)

    ~H"""
    <div class="flex flex-col mx-auto max-w-none sm:px-4 py-2 sm:py-6 gap-4">
      <.admin_page_header title={@page_title}>
        <:actions>
          <%!-- Draft state: Save draft + Cancel + Ship --%>
          <%= if @draft? and @active_tab in [:general, :items] do %>
            <button type="button" phx-click="save_draft" class="btn btn-ghost btn-sm">
              {dgettext("default", "Save draft")}
            </button>
            <button type="button" phx-click="cancel" class="btn btn-outline btn-error btn-sm">
              {dgettext("default", "Cancel")}
            </button>
            <button type="button" phx-click="ship" class="btn btn-primary btn-sm">
              <.icon name="hero-truck" class="w-4 h-4" /> {dgettext("default", "Ship")}
            </button>
          <% end %>
          <%!-- In transit: Cancel (confirm) + Receive --%>
          <%= if @in_transit? and @active_tab in [:general, :items] do %>
            <button
              type="button"
              phx-click="open_cancel_confirm"
              class="btn btn-outline btn-error btn-sm"
            >
              {dgettext("default", "Cancel")}
            </button>
            <button type="button" phx-click="receive" class="btn btn-primary btn-sm">
              <.icon name="hero-check" class="w-4 h-4" /> {dgettext("default", "Receive")}
            </button>
          <% end %>
          <%!-- Terminal state + admin: note correction --%>
          <%= if @terminal? and @admin? and @active_tab == :general do %>
            <button type="button" phx-click="save_correction" class="btn btn-ghost btn-sm">
              {dgettext("default", "Save correction")}
            </button>
          <% end %>
          <%!-- Status badge (in_transit / done / cancelled) --%>
          <%= if @transfer do %>
            <span
              :if={@transfer.status != "draft"}
              class={["badge badge-lg", status_badge_class(@transfer.status)]}
            >
              {status_label(@transfer.status)}
            </span>
          <% end %>
        </:actions>
      </.admin_page_header>

      <%!-- Tab navigation --%>
      <div class="tabs tabs-border">
        <.link
          patch={Routes.path("/admin/warehouse/transfers/#{@transfer_uuid}")}
          class={["tab", @active_tab == :general && "tab-active"]}
        >
          {dgettext("default", "General")}
        </.link>
        <.link
          :if={@transfer_uuid}
          patch={Routes.path("/admin/warehouse/transfers/#{@transfer_uuid}/items")}
          class={["tab", @active_tab == :items && "tab-active"]}
        >
          {dgettext("default", "Items")}
        </.link>
        <.link
          :if={@transfer_uuid}
          patch={Routes.path("/admin/warehouse/transfers/#{@transfer_uuid}/files")}
          class={["tab", @active_tab == :files && "tab-active"]}
        >
          {dgettext("default", "Files")}
        </.link>
        <.link
          :if={@transfer_uuid}
          patch={Routes.path("/admin/warehouse/transfers/#{@transfer_uuid}/comments")}
          class={["tab", @active_tab == :comments && "tab-active"]}
        >
          {dgettext("default", "Comments")}
          <span :if={@comment_count > 0} class="badge badge-sm badge-ghost ml-1">
            {@comment_count}
          </span>
        </.link>
      </div>

      <%!-- Status info banner (non-admin only) --%>
      <%= if @transfer && @transfer.status != "draft" and not @admin? do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>{transfer_status_banner(@transfer.status)}</span>
        </div>
      <% end %>

      <%!-- Tab: General --%>
      <%= if @active_tab == :general do %>
        <%= if @draft? do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4 flex flex-col gap-3">
              <div>
                <form phx-change="set_note" phx-submit="set_note">
                  <input
                    type="text"
                    id="tr-note-input"
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
          </div>
        <% end %>

        <%= if @transfer do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4">
              <dl class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-sm">
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Number")}</dt>
                  <dd class="mt-0.5 font-mono">#TR-{@transfer.number}</dd>
                </div>
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Status")}</dt>
                  <dd class="mt-0.5">
                    <span class={["badge badge-sm", status_badge_class(@transfer.status)]}>
                      {status_label(@transfer.status)}
                    </span>
                  </dd>
                </div>
                <%= if @transfer.inserted_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Created")}
                    </dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@transfer.inserted_at, "%Y-%m-%d %H:%M")}
                    </dd>
                  </div>
                <% end %>
                <%= if @transfer.shipped_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Shipped at")}
                    </dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@transfer.shipped_at, "%Y-%m-%d %H:%M")}
                    </dd>
                  </div>
                <% end %>
                <%= if @transfer.received_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Received at")}
                    </dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@transfer.received_at, "%Y-%m-%d %H:%M")}
                    </dd>
                  </div>
                <% end %>
                <%= if @transfer.cancelled_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Cancelled at")}
                    </dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@transfer.cancelled_at, "%Y-%m-%d %H:%M")}
                    </dd>
                  </div>
                <% end %>
                <div>
                  <dt class="text-base-content/60 font-medium">
                    {dgettext("default", "Source warehouse")}
                  </dt>
                  <dd class="mt-0.5">
                    <.location_field
                      editable?={@editable_locations? and warehouse_options?(@warehouses)}
                      warehouses={@warehouses}
                      selected_uuid={@transfer.source_location_uuid}
                      location_name={@source_location_name}
                      event="set_source_location"
                    />
                  </dd>
                </div>
                <div>
                  <dt class="text-base-content/60 font-medium">
                    {dgettext("default", "Destination warehouse")}
                  </dt>
                  <dd class="mt-0.5">
                    <.location_field
                      editable?={@editable_locations? and warehouse_options?(@warehouses)}
                      warehouses={@warehouses}
                      selected_uuid={@transfer.destination_location_uuid}
                      location_name={@destination_location_name}
                      event="set_destination_location"
                    />
                  </dd>
                </div>
                <%= if @transfer.note && !@draft? do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Note")}
                    </dt>
                    <dd class="mt-0.5">{@transfer.note}</dd>
                  </div>
                <% end %>
              </dl>
              <%!-- Related documents (manual links only — no downstream refs) --%>
              <RelatedDocuments.related_documents
                upstream={@source_refs}
                downstream={[]}
                upstream_label={dgettext("default", "Source documents")}
                downstream_label={dgettext("default", "Related documents")}
              />
              <%!-- Note correction on a terminal transfer (admin only) --%>
              <%= if @terminal? and @admin? do %>
                <div class="divider my-1"></div>
                <div class="text-sm">
                  <label class="text-base-content/60 font-medium block mb-1">
                    {dgettext("default", "Note")}
                  </label>
                  <form phx-change="set_note" phx-submit="set_note">
                    <input
                      type="text"
                      id="tr-note-posted-input"
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
                  {dgettext("default", "Files are not available for this transfer yet.")}
                </div>
              <% true -> %>
                <.live_component
                  module={PhoenixKitWeb.Components.MediaBrowser}
                  id={"media-browser-tr-#{@transfer_uuid}"}
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
                kind={:transfer}
                resource_uuid={@transfer_uuid}
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

      <%!-- Tab: Items --%>
      <%= if @active_tab == :items do %>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-center justify-between gap-2 mb-2">
              <h2 class="card-title text-base">{dgettext("default", "Items")}</h2>
              <%= if @draft? do %>
                <button type="button" phx-click="open_add_picker" class="btn btn-primary btn-sm">
                  <.icon name="hero-plus" class="w-4 h-4" />
                  {dgettext("default", "Add item")}
                </button>
              <% end %>
            </div>
            <.transfer_lines_table
              lines={@lines}
              names={@names}
              editable?={!!@draft?}
            />
          </div>
        </div>

        <%!-- Add item modal (draft only) --%>
        <%= if @draft? do %>
          <.modal
            show={@show_add_picker_modal}
            on_close="close_add_picker"
            max_width="3xl"
            max_height="80vh"
          >
            <:title>{dgettext("default", "Add item")}</:title>
            <div class="flex flex-wrap items-center justify-between gap-3 mb-3">
              <div class="flex items-center gap-1">
                <span class="text-xs text-base-content/60 mr-1">
                  {dgettext("default", "After add:")}
                </span>
                <div class="join">
                  <button
                    type="button"
                    phx-click="set_add_mode"
                    phx-value-mode="one"
                    class={[
                      "btn btn-xs join-item",
                      @add_mode == :one && "btn-primary",
                      @add_mode != :one && "btn-ghost"
                    ]}
                  >
                    {dgettext("default", "Close")}
                  </button>
                  <button
                    type="button"
                    phx-click="set_add_mode"
                    phx-value-mode="many"
                    class={[
                      "btn btn-xs join-item",
                      @add_mode == :many && "btn-primary",
                      @add_mode != :many && "btn-ghost"
                    ]}
                  >
                    {dgettext("default", "Keep open")}
                  </button>
                </div>
              </div>
              <div class="flex items-center gap-1">
                <span class="text-xs text-base-content/60 mr-1">
                  {dgettext("default", "View:")}
                </span>
                <div class="join">
                  <button
                    type="button"
                    phx-click="set_search_mode"
                    phx-value-mode="list"
                    class={[
                      "btn btn-xs join-item",
                      @search_mode == :list && "btn-primary",
                      @search_mode != :list && "btn-ghost"
                    ]}
                  >
                    {dgettext("default", "List")}
                  </button>
                  <button
                    type="button"
                    phx-click="set_search_mode"
                    phx-value-mode="tree"
                    class={[
                      "btn btn-xs join-item",
                      @search_mode == :tree && "btn-primary",
                      @search_mode != :tree && "btn-ghost"
                    ]}
                  >
                    {dgettext("default", "Tree")}
                  </button>
                </div>
              </div>
            </div>
            <div class="min-h-[28rem]">
              <WarehouseBrowser.add_picker
                catalogue_summaries={@catalogue_summaries}
                expanded_catalogues={@expanded_catalogues}
                expanded_categories={@expanded_categories}
                loaded_categories={@loaded_categories}
                loaded_items={@loaded_items}
                locale={@locale}
                present_item_uuids={present_uuids(@lines)}
                item_search_query={@item_search_query}
                item_search_results={@item_search_results}
                search_mode={@search_mode}
              />
            </div>
            <:actions>
              <button type="button" phx-click="close_add_picker" class="btn btn-sm">
                {dgettext("default", "Done")}
              </button>
            </:actions>
          </.modal>
        <% end %>
      <% end %>

      <%!-- Source picker modal: attach a manual link (no line import) --%>
      <WarehouseBrowser.source_picker
        id="tr-source-picker"
        show={@show_source_picker}
        title={dgettext("default", "Attach a document")}
        on_close="close_source_picker"
        candidates={@source_picker_candidates}
        selected_uuids={@source_picker_selected}
        search_query={@source_picker_query}
      />

      <%!-- Cancel confirmation modal (in_transit only — reverses a real posting) --%>
      <.modal show={@show_cancel_confirm_modal} on_close="close_cancel_confirm">
        <:title>{dgettext("default", "Cancel this transfer?")}</:title>
        <p>
          {dgettext(
            "default",
            "This will reverse the shipment and credit the quantity back to the source warehouse. This cannot be undone."
          )}
        </p>
        <:actions>
          <button type="button" phx-click="close_cancel_confirm" class="btn btn-sm">
            {dgettext("default", "Keep transfer")}
          </button>
          <button type="button" phx-click="cancel" class="btn btn-error btn-sm">
            {dgettext("default", "Cancel transfer")}
          </button>
        </:actions>
      </.modal>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Function components
  # ---------------------------------------------------------------------------

  attr(:editable?, :boolean, required: true)
  attr(:warehouses, :any, required: true)
  attr(:selected_uuid, :string, default: nil)
  attr(:location_name, :string, default: nil)
  attr(:event, :string, required: true)

  defp location_field(assigns) do
    ~H"""
    <%= if @editable? do %>
      <form phx-change={@event} phx-submit={@event}>
        <select name="location_uuid" class="select select-sm select-bordered">
          <option value="" selected={is_nil(@selected_uuid)}>
            {dgettext("default", "— select —")}
          </option>
          <%= for warehouse <- @warehouses do %>
            <option value={warehouse.uuid} selected={@selected_uuid == warehouse.uuid}>
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
    """
  end

  attr(:lines, :list, required: true)
  attr(:names, :map, required: true)
  attr(:editable?, :boolean, required: true)

  defp transfer_lines_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>{dgettext("default", "Item")}</th>
            <th class="w-16 text-center">{dgettext("default", "Unit")}</th>
            <th class="w-32 text-center">{dgettext("default", "Transfer qty")}</th>
            <%= if @editable? do %>
              <th class="w-12"></th>
            <% end %>
          </tr>
        </thead>
        <tbody>
          <%= if @lines == [] do %>
            <tr>
              <td colspan="4" class="text-center text-base-content/50 py-4">
                {dgettext("default", "No items yet")}
              </td>
            </tr>
          <% end %>
          <%= for {line, index} <- Enum.with_index(@lines) do %>
            <tr class="hover">
              <td>
                <div class="font-medium">
                  {Map.get(@names, line["item_uuid"]) || line["name"] || "—"}
                </div>
                <div :if={line["sku"]} class="text-xs text-base-content/50 font-mono">
                  {line["sku"]}
                </div>
              </td>
              <td class="text-center text-xs text-base-content/60">
                {WarehouseBrowser.unit_label(line["unit"])}
              </td>
              <td class="text-center">
                <%= if @editable? do %>
                  <form
                    id={"tr-qty-form-#{index}"}
                    phx-change="set_transfer_qty"
                    phx-submit="set_transfer_qty"
                  >
                    <input type="hidden" name="index" value={index} />
                    <input
                      type="number"
                      id={"tr-qty-#{index}"}
                      name="transfer_quantity"
                      min="0"
                      step="any"
                      value={line["transfer_quantity"] || ""}
                      placeholder="0"
                      class="input input-sm w-24 text-center"
                      phx-debounce="blur"
                      phx-hook="InvEnterBlur"
                    />
                  </form>
                <% else %>
                  <span class="tabular-nums">{line["transfer_quantity"] || "—"}</span>
                <% end %>
              </td>
              <%= if @editable? do %>
                <td>
                  <button
                    type="button"
                    phx-click="remove_line"
                    phx-value-index={index}
                    class="btn btn-ghost btn-xs text-error"
                    title={dgettext("default", "Remove")}
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </td>
              <% end %>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # File folder resolution / comments subscription
  # ---------------------------------------------------------------------------

  defp maybe_start_files_folder_resolution(socket) do
    cond do
      not is_nil(socket.assigns.files_scope_folder_uuid) ->
        socket

      not connected?(socket) ->
        assign(socket, :files_folder_loading, true)

      true ->
        lv_pid = self()
        transfer = socket.assigns.transfer
        user_uuid = socket.assigns.current_user && socket.assigns.current_user.uuid

        Task.Supervisor.start_child(PhoenixKitWarehouse.TaskSupervisor, fn ->
          result = StorageFolders.ensure_for_transfer(transfer, user_uuid)
          send(lv_pid, {:files_folder_result, result})
        end)

        assign(socket, :files_folder_loading, true)
    end
  end

  defp maybe_subscribe_and_refresh_comments(socket) do
    transfer = socket.assigns.transfer

    if connected?(socket) and transfer do
      socket =
        if socket.assigns.comments_subscribed? do
          socket
        else
          Comments.subscribe(:transfer, [transfer.uuid])
          assign(socket, :comments_subscribed?, true)
        end

      count = Comments.count(:transfer, transfer.uuid)
      assign(socket, :comment_count, count)
    else
      socket
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_catalogue_summaries(catalogues) do
    Enum.map(catalogues, fn catalogue -> %{catalogue: catalogue} end)
  end

  defp ensure_catalogue_categories_loaded(socket, catalogue_uuid) do
    if Map.has_key?(socket.assigns.loaded_categories, catalogue_uuid) do
      socket
    else
      summary = Catalogue.category_summary_for_catalogue(catalogue_uuid)

      categories =
        summary.categories
        |> Enum.map(fn cat -> %{category: cat} end)
        |> then(fn cats ->
          if summary.uncategorized_count > 0 do
            cats ++ [%{category: nil}]
          else
            cats
          end
        end)

      loaded = Map.put(socket.assigns.loaded_categories, catalogue_uuid, categories)
      assign(socket, :loaded_categories, loaded)
    end
  end

  defp ensure_category_items_loaded(socket, catalogue_uuid, cat_key) do
    tuple = {catalogue_uuid, cat_key}

    if Map.has_key?(socket.assigns.loaded_items, tuple) do
      socket
    else
      items =
        if cat_key == "uncategorized" do
          Catalogue.list_uncategorized_items(catalogue_uuid)
        else
          Catalogue.list_items_for_category(cat_key)
        end

      loaded = Map.put(socket.assigns.loaded_items, tuple, items)
      assign(socket, :loaded_items, loaded)
    end
  end

  defp focus_qty_input(socket, nil), do: socket

  defp focus_qty_input(socket, index) do
    push_event(socket, "inv-focus-counted", %{id: "tr-qty-#{index}"})
  end

  defp add_item_to_lines(socket, item_uuid) do
    lines = socket.assigns.lines
    locale = socket.assigns.locale

    already_present? = Enum.any?(lines, &(&1["item_uuid"] == item_uuid))

    lines =
      if already_present? do
        lines
      else
        item = Catalogue.get_item!(item_uuid)

        new_line = %{
          "item_uuid" => item_uuid,
          "name" => WarehouseBrowser.localized_name(item, locale),
          "sku" => item.sku,
          "catalogue_uuid" => item.catalogue_uuid,
          "category_uuid" => item.category_uuid,
          "unit" => item.unit,
          "transfer_quantity" => "0"
        }

        lines ++ [new_line]
      end

    names = build_names_map(lines, locale)

    socket
    |> assign(:lines, lines)
    |> assign(:names, names)
  end

  defp build_names_map(lines, locale) do
    item_uuids = lines |> Enum.map(& &1["item_uuid"]) |> Enum.filter(& &1) |> Enum.uniq()

    items =
      if item_uuids == [],
        do: [],
        else: Catalogue.list_items_by_uuids(item_uuids)

    Map.new(items, fn item ->
      {item.uuid, WarehouseBrowser.localized_name(item, locale)}
    end)
  end

  defp ensure_saved(%Transfer{status: "draft"} = transfer, attrs) do
    Transfers.update_draft(transfer, attrs)
  end

  defp ensure_saved(%Transfer{} = transfer, _attrs) do
    {:ok, transfer}
  end

  defp present_uuids(lines) do
    lines
    |> Enum.map(& &1["item_uuid"])
    |> Enum.filter(& &1)
    |> MapSet.new()
  end

  defp update_location(socket, field, raw_uuid) do
    uuid = blank_to_nil(raw_uuid)

    case socket.assigns.transfer do
      %Transfer{status: "draft"} = transfer ->
        case Transfers.update_draft(transfer, %{field => uuid}) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:transfer, updated)
             |> assign(
               :source_location_name,
               resolve_location_name(updated.source_location_uuid)
             )
             |> assign(
               :destination_location_name,
               resolve_location_name(updated.destination_location_uuid)
             )
             |> put_flash(:info, dgettext("default", "Warehouse changed"))}

          {:error, _changeset} ->
            {:noreply,
             put_flash(socket, :error, dgettext("default", "Failed to change warehouse"))}
        end

      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("default", "Cannot modify: document is not a draft"))}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  # `list_warehouses/0` returns nil when the warehouse LocationType isn't
  # configured yet, or [] when configured but empty — neither is selectable.
  defp warehouse_options?(nil), do: false
  defp warehouse_options?([]), do: false
  defp warehouse_options?(_), do: true

  defp status_label("draft"), do: dgettext("default", "Draft")
  defp status_label("in_transit"), do: dgettext("default", "In transit")
  defp status_label("done"), do: dgettext("default", "Done")
  defp status_label("cancelled"), do: dgettext("default", "Cancelled")
  defp status_label(other), do: other

  defp status_badge_class("draft"), do: "badge-ghost"
  defp status_badge_class("in_transit"), do: "badge-warning"
  defp status_badge_class("done"), do: "badge-success"
  defp status_badge_class("cancelled"), do: "badge-error"
  defp status_badge_class(_other), do: "badge-ghost"

  defp transfer_status_banner("in_transit"),
    do:
      dgettext(
        "default",
        "This transfer is in transit. Stock has left the source warehouse."
      )

  defp transfer_status_banner("done"),
    do: dgettext("default", "This transfer has been received and is now read-only.")

  defp transfer_status_banner("cancelled"),
    do: dgettext("default", "This transfer has been cancelled.")

  defp transfer_status_banner(_other), do: nil
end
