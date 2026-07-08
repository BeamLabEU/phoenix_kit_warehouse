defmodule PhoenixKitWarehouse.Web.InventoryFormLive do
  @moduledoc """
  LiveView for creating and editing inventory documents.

  Handles:
  - `:new`      — creates a draft and push_navigate to :edit path.
  - `:edit`     — loads an existing document; :general tab.
  - `:items`    — count sheet + add picker (draft only).
  - `:files`    — MediaBrowser; storage folder resolved asynchronously.
  - `:comments` — inventory comments thread.

  Uses the admin-chrome pattern: `use PhoenixKitWeb, :live_view` +
  `<.admin_page_header>`. No `<Layouts.app>`, no streams.
  All navigation paths wrapped in `PhoenixKit.Utils.Routes.path/1`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWarehouse.Gettext
  use PhoenixKitComments.Embed

  import PhoenixKitBilling.Web.Components.CurrencyDisplay, only: [currency_compact: 1]

  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.ActivityLog
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.Comments
  alias PhoenixKitWarehouse.StorageFolders
  alias PhoenixKitWarehouse.Web.Components.{CommentsPanel, WarehouseBrowser}

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    locale = socket.assigns[:current_locale] || Gettext.get_locale()

    scope = socket.assigns[:phoenix_kit_current_scope]
    current_user = scope && PhoenixKit.Users.Auth.Scope.user(scope)
    admin? = !!(scope && PhoenixKit.Users.Auth.Scope.admin?(scope))

    stock_map = StockLedger.stock_map()

    comments_available? = Comments.available?()

    catalogue_summaries = load_catalogue_summaries(Catalogue.list_catalogues(status: "active"))

    socket =
      socket
      |> assign(:locale, locale)
      |> assign(:current_user, current_user)
      |> assign(:admin?, admin?)
      |> assign(:stock_map, stock_map)
      |> assign(:show_add_picker_modal, false)
      # Will be set in handle_params
      |> assign(:doc, nil)
      |> assign(:lines, [])
      |> assign(:track_value, false)
      |> assign(:note, "")
      |> assign(:names, %{})
      |> assign(:active_tab, :general)
      |> assign(:files_scope_folder_uuid, nil)
      |> assign(:files_folder_loading, false)
      |> assign(:comments_available?, comments_available?)
      |> assign(:inventory_comment_count, 0)
      |> assign(:comments_subscribed?, false)
      |> assign(:selectable_users, [])
      |> assign(:location_name, nil)
      |> assign(:page_title, dgettext("default", "Stocktake"))
      # Add-picker tree state
      |> assign(:catalogue_summaries, catalogue_summaries)
      |> assign(:expanded_catalogues, MapSet.new())
      |> assign(:expanded_categories, MapSet.new())
      |> assign(:loaded_categories, %{})
      |> assign(:loaded_items, %{})
      |> assign(:item_search_query, "")
      |> assign(:item_search_results, nil)
      |> assign(:add_mode, :one)
      |> assign(:search_mode, :list)
      |> PhoenixKitWeb.Components.MediaBrowser.setup_uploads()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    locale = socket.assigns.locale
    action = socket.assigns.live_action

    case action do
      :new ->
        handle_params_new(socket, locale)

      :edit ->
        uuid = params["uuid"]
        socket = load_doc_into_socket(socket, uuid, locale)

        socket =
          socket
          |> assign(:active_tab, :general)
          |> maybe_subscribe_and_refresh_comments()

        {:noreply, socket}

      :items ->
        uuid = params["uuid"]
        socket = load_doc_into_socket(socket, uuid, locale)

        socket =
          socket
          |> assign(:active_tab, :items)
          |> maybe_subscribe_and_refresh_comments()

        {:noreply, socket}

      :files ->
        uuid = params["uuid"]
        socket = load_doc_into_socket(socket, uuid, locale)

        socket =
          socket
          |> assign(:active_tab, :files)
          |> maybe_start_files_folder_resolution()
          |> maybe_subscribe_and_refresh_comments()

        {:noreply, socket}

      :comments ->
        uuid = params["uuid"]
        socket = load_doc_into_socket(socket, uuid, locale)

        socket =
          socket
          |> assign(:active_tab, :comments)
          |> maybe_subscribe_and_refresh_comments()

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # Subscribes once (idempotent flag) and refreshes comment count.
  # Safe to call from multiple handle_params clauses.
  defp maybe_subscribe_and_refresh_comments(socket) do
    doc = socket.assigns.doc

    if connected?(socket) and doc do
      socket =
        if socket.assigns.comments_subscribed? do
          socket
        else
          Comments.subscribe(:inventory, [doc.uuid])
          assign(socket, :comments_subscribed?, true)
        end

      count = Comments.count(:inventory, doc.uuid)
      assign(socket, :inventory_comment_count, count)
    else
      socket
    end
  end

  defp handle_params_new(socket, locale) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    current_user = scope && PhoenixKit.Users.Auth.Scope.user(scope)
    user_uuid = current_user && current_user.uuid

    attrs = %{
      lines: Inventories.seed_lines(locale),
      created_by_uuid: user_uuid
    }

    case Inventories.create_draft(attrs) do
      {:ok, doc} ->
        ActivityLog.log_created(doc, actor: current_user)

        {:noreply,
         push_navigate(socket,
           to: Routes.path("/admin/warehouse/inventory/#{doc.uuid}")
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to create draft"))}
    end
  end

  # Loads doc into socket assigns; also loads selectable_users for admin
  # (or the two specific referenced users for non-admins, for display-name resolution),
  # and the warehouse location name. The edit buffer (lines/track_value/note) is
  # only (re)initialised when first opening a document — see assign_edit_buffer/3.
  defp load_doc_into_socket(socket, uuid, locale) do
    doc = Inventories.get_document!(uuid)
    same_doc? = match?(%{uuid: ^uuid}, socket.assigns[:doc])

    selectable_users =
      if socket.assigns.admin? do
        # Staff assignable as responsible/creator: Owners + Admins. Always merge
        # in the users already referenced by the doc so the selects can render
        # the current value even when that user's role isn't Owner/Admin.
        staff =
          Auth.list_users_paginated(role: "Owner", page_size: 100).users ++
            Auth.list_users_paginated(role: "Admin", page_size: 100).users

        (staff ++ referenced_users(doc))
        |> Enum.uniq_by(& &1.uuid)
        |> Enum.sort_by(&String.downcase(&1.email || ""))
      else
        # Read-only mode: only the referenced users, for display-name resolution.
        referenced_users(doc)
      end

    socket =
      socket
      |> assign(:doc, doc)
      |> assign(:selectable_users, selectable_users)
      |> assign(:location_name, resolve_location_name(doc.location_uuid))
      |> assign(:page_title, dgettext("default", "Stocktake #%{n}", n: doc.number))

    # Initialise the edit buffer only when first opening this document. Preserves
    # unsaved edits (Track value toggle, note, entered counts, added/removed
    # lines) across tab navigation within the same document.
    if same_doc?, do: socket, else: assign_edit_buffer(socket, doc, locale)
  end

  # (Re)initialises the editable buffer from a document. Called on first open and
  # explicitly after repost (to pick up the freshly audited lines).
  defp assign_edit_buffer(socket, doc, locale) do
    socket
    |> assign(:lines, doc.lines)
    |> assign(:track_value, doc.track_value)
    |> assign(:note, doc.note || "")
    |> assign(:names, build_names_map(doc.lines, locale))
  end

  # Users referenced by the doc (responsible + creator), fetched for display.
  defp referenced_users(doc) do
    [doc.performed_by_uuid, doc.created_by_uuid]
    |> Enum.filter(& &1)
    |> Enum.uniq()
    |> Enum.flat_map(fn user_uuid ->
      case Auth.get_user(user_uuid) do
        nil -> []
        user -> [user]
      end
    end)
  end

  # Returns the display name for a location uuid, or a fallback string.
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
        doc = socket.assigns.doc
        user_uuid = socket.assigns.current_user && socket.assigns.current_user.uuid

        Task.Supervisor.start_child(PhoenixKitWarehouse.TaskSupervisor, fn ->
          result = StorageFolders.ensure_for_inventory(doc, user_uuid)
          send(lv_pid, {:files_folder_result, result})
        end)

        assign(socket, :files_folder_loading, true)
    end
  end

  # ---------------------------------------------------------------------------
  # Add picker modal handlers
  # ---------------------------------------------------------------------------

  # MediaBrowser allows the `:media_files` upload on this parent LiveView
  # (see setup_uploads/1), so its `phx-change="validate"` channel fires here.
  # Absorb it to avoid a FunctionClauseError crash on file upload.
  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

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

  # Per-item add from the picker tree or search results.
  @impl true
  def handle_event("add_position", %{"item_uuid" => item_uuid}, socket) do
    posted? = socket.assigns.doc && socket.assigns.doc.status == "posted"
    editable? = !posted? || socket.assigns.admin?

    socket =
      if editable? do
        socket = add_item_to_lines(socket, item_uuid)

        case socket.assigns.add_mode do
          :one ->
            index = Enum.find_index(socket.assigns.lines, &(&1["item_uuid"] == item_uuid))

            socket
            |> assign(:show_add_picker_modal, false)
            |> focus_counted_input(index)

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
  def handle_event("set_counted", params, socket) do
    index = String.to_integer(params["index"])
    raw = params["counted_quantity"] || "0"

    qty =
      raw
      |> StockLedger.to_decimal()
      |> clamp_non_negative()

    lines =
      socket.assigns.lines
      |> List.update_at(index, fn line ->
        unit_value = StockLedger.to_decimal_or_nil(line["unit_value"])

        sum =
          if unit_value,
            do: Decimal.mult(qty, unit_value) |> Decimal.round(2),
            else: nil

        line
        |> Map.put("counted_quantity", qty)
        |> Map.put("_sum", sum)
      end)

    {:noreply, assign(socket, :lines, lines)}
  end

  @impl true
  def handle_event("set_price", params, socket) do
    index = String.to_integer(params["index"])
    raw = params["unit_value"] || ""

    unit_value = StockLedger.to_decimal_or_nil(raw)

    lines =
      socket.assigns.lines
      |> List.update_at(index, fn line ->
        qty = StockLedger.to_decimal(line["counted_quantity"])

        sum =
          if unit_value,
            do: Decimal.mult(qty, unit_value) |> Decimal.round(2),
            else: nil

        line
        |> Map.put("unit_value", unit_value)
        |> Map.put("_sum", sum)
      end)

    {:noreply, assign(socket, :lines, lines)}
  end

  @impl true
  def handle_event("set_sum", params, socket) do
    index = String.to_integer(params["index"])
    raw = params["sum"] || "0"

    sum = StockLedger.to_decimal_or_nil(raw)

    lines =
      socket.assigns.lines
      |> List.update_at(index, fn line ->
        qty = StockLedger.to_decimal(line["counted_quantity"])
        zero = Decimal.new("0")

        unit_value =
          cond do
            is_nil(sum) ->
              line["unit_value"]

            Decimal.compare(qty, zero) == :gt ->
              Decimal.div(sum, qty) |> Decimal.round(2)

            true ->
              line["unit_value"]
          end

        Map.put(line, "unit_value", unit_value)
      end)

    {:noreply, assign(socket, :lines, lines)}
  end

  @impl true
  def handle_event("toggle_track_value", _params, socket) do
    {:noreply, assign(socket, :track_value, !socket.assigns.track_value)}
  end

  @impl true
  def handle_event("set_note", %{"note" => note}, socket) do
    {:noreply, assign(socket, :note, note)}
  end

  # ---------------------------------------------------------------------------
  # Responsibility update (admin-only, server-side guard)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("set_responsibility", _params, %{assigns: %{admin?: false}} = socket) do
    {:noreply, put_flash(socket, :error, dgettext("default", "Not authorized"))}
  end

  def handle_event("set_responsibility", params, socket) do
    doc = socket.assigns.doc
    attrs = Map.take(params, ["created_by_uuid", "performed_by_uuid"])

    case Inventories.update_responsibility(doc, attrs) do
      {:ok, updated_doc} ->
        changes =
          %{}
          |> maybe_add_responsibility_change(
            :created_by,
            doc.created_by_uuid,
            updated_doc.created_by_uuid
          )
          |> maybe_add_responsibility_change(
            :performed_by,
            doc.performed_by_uuid,
            updated_doc.performed_by_uuid
          )

        ActivityLog.log_responsibility_changed(updated_doc, changes,
          actor: socket.assigns.current_user
        )

        {:noreply, assign(socket, :doc, updated_doc)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to update"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Save draft
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_draft", _params, socket) do
    attrs = %{
      track_value: socket.assigns.track_value,
      note: socket.assigns.note,
      lines: socket.assigns.lines
    }

    case socket.assigns.doc do
      %PhoenixKitWarehouse.InventoryDocument{status: "draft"} = doc ->
        changes = diff_doc_changes(doc, attrs)

        case Inventories.update_draft(doc, attrs) do
          {:ok, updated_doc} ->
            ActivityLog.log_draft_saved(updated_doc, changes, actor: socket.assigns.current_user)

            {:noreply,
             socket
             |> assign(:doc, updated_doc)
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
  # Post
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("post", _params, socket) do
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid

    save_attrs = %{
      track_value: socket.assigns.track_value,
      note: socket.assigns.note,
      lines: socket.assigns.lines
    }

    doc = socket.assigns.doc

    with {:ok, saved_doc} <- ensure_saved(doc, save_attrs, user_uuid),
         {:ok, posted_doc} <- Inventories.post_document(saved_doc, user_uuid) do
      ActivityLog.log_posted(posted_doc, actor: current_user)

      {:noreply,
       socket
       |> put_flash(:info, dgettext("default", "Stocktake conducted"))
       |> push_navigate(to: Routes.path("/admin/warehouse"))}
    else
      {:error, :not_draft} ->
        {:noreply,
         put_flash(socket, :error, dgettext("default", "Document is already conducted"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to conduct stocktake"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Save correction (admin-only)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_correction", _params, %{assigns: %{admin?: false}} = socket) do
    {:noreply, put_flash(socket, :error, dgettext("default", "Not authorized"))}
  end

  def handle_event("save_correction", _params, socket) do
    doc = socket.assigns.doc

    attrs = %{
      track_value: socket.assigns.track_value,
      note: socket.assigns.note,
      lines: socket.assigns.lines
    }

    changes = diff_doc_changes(doc, attrs)

    case Inventories.correct_document(doc, attrs) do
      {:ok, corrected_doc} ->
        ActivityLog.log_corrected(corrected_doc, changes, actor: socket.assigns.current_user)

        {:noreply,
         socket
         |> assign(:doc, corrected_doc)
         |> put_flash(:info, dgettext("default", "Correction saved"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to save correction"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Repost (admin-only)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("repost", _params, %{assigns: %{admin?: false}} = socket) do
    {:noreply, put_flash(socket, :error, dgettext("default", "Not authorized"))}
  end

  def handle_event("repost", _params, socket) do
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid
    doc = socket.assigns.doc

    pending_attrs = %{
      track_value: socket.assigns.track_value,
      note: socket.assigns.note,
      lines: socket.assigns.lines
    }

    with {:ok, corrected_doc} <- Inventories.correct_document(doc, pending_attrs),
         {:ok, reposted_doc} <- Inventories.repost_document(corrected_doc, user_uuid) do
      ActivityLog.log_reposted(reposted_doc, actor: current_user)

      locale = socket.assigns.locale

      socket =
        socket
        |> load_doc_into_socket(reposted_doc.uuid, locale)
        |> assign_edit_buffer(reposted_doc, locale)

      {:noreply,
       socket
       |> put_flash(:info, dgettext("default", "Stocktake re-conducted"))}
    else
      {:error, :not_posted} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Document is not posted"))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, dgettext("default", "Failed to re-conduct stocktake"))}
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
     |> put_flash(:error, "Could not open files folder: #{inspect(reason)}")}
  end

  def handle_info({:comments_updated, _payload}, socket) do
    count =
      case socket.assigns.doc do
        %{uuid: uuid} when not is_nil(uuid) ->
          Comments.count(:inventory, uuid)

        _ ->
          0
      end

    {:noreply, assign(socket, :inventory_comment_count, count)}
  end

  # Delegate MediaBrowser parent messages to the canonical handler.
  def handle_info({PhoenixKitWeb.Components.MediaBrowser, _action, _payload} = msg, socket) do
    PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
  end

  # Catch-all: silently drop any unmatched process message (e.g. stale PubSub
  # broadcasts, unexpected CommentsComponent payloads after a library upgrade).
  # Prevents a FunctionClauseError from crashing the LiveView.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:posted?, assigns.doc && assigns.doc.status == "posted")
      |> assign(:doc_uuid, assigns.doc && assigns.doc.uuid)

    assigns = assign(assigns, :editable?, !assigns.posted? || assigns.admin?)

    # Grand total value across all lines (shown next to the Count sheet title
    # only when track_value is on).
    assigns =
      assign(
        assigns,
        :items_value_total,
        Enum.reduce(assigns.lines, Decimal.new(0), fn line, acc ->
          case StockLedger.to_decimal_or_nil(line["unit_value"]) do
            nil ->
              acc

            uv ->
              Decimal.add(acc, Decimal.mult(StockLedger.to_decimal(line["counted_quantity"]), uv))
          end
        end)
      )

    ~H"""
    <div class="flex flex-col mx-auto max-w-none sm:px-4 py-2 sm:py-6 gap-4">
      <.admin_page_header title={@page_title}>
        <:actions>
          <%!-- Draft state: Save draft + Conduct --%>
          <%= if !@posted? and @active_tab in [:general, :items] do %>
            <button
              type="button"
              phx-click="save_draft"
              class="btn btn-ghost btn-sm"
            >
              {dgettext("default", "Save draft")}
            </button>
            <button
              type="button"
              phx-click="post"
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-check" class="w-4 h-4" />
              {dgettext("default", "Conduct")}
            </button>
          <% end %>
          <%!-- Posted + admin: correction + repost + badge --%>
          <%= if @posted? and @admin? and @active_tab in [:general, :items] do %>
            <button
              type="button"
              phx-click="save_correction"
              class="btn btn-ghost btn-sm"
            >
              {dgettext("default", "Save correction")}
            </button>
            <button
              type="button"
              phx-click="repost"
              class="btn btn-warning btn-sm"
            >
              <.icon name="hero-arrow-path" class="w-4 h-4" />
              {dgettext("default", "Re-conduct")}
            </button>
          <% end %>
          <%!-- Posted badge (always shown when posted) --%>
          <%= if @posted? do %>
            <span class="badge badge-success badge-lg">
              {dgettext("default", "Conducted")}
            </span>
          <% end %>
        </:actions>
      </.admin_page_header>

      <%!-- Tab navigation --%>
      <div class="tabs tabs-border">
        <.link
          patch={Routes.path("/admin/warehouse/inventory/#{@doc_uuid}")}
          class={["tab", @active_tab == :general && "tab-active"]}
        >
          {dgettext("default", "General")}
        </.link>
        <.link
          :if={@doc_uuid}
          patch={Routes.path("/admin/warehouse/inventory/#{@doc_uuid}/items")}
          class={["tab", @active_tab == :items && "tab-active"]}
        >
          {dgettext("default", "Items")}
        </.link>
        <.link
          :if={@doc_uuid}
          patch={Routes.path("/admin/warehouse/inventory/#{@doc_uuid}/files")}
          class={["tab", @active_tab == :files && "tab-active"]}
        >
          {dgettext("default", "Files")}
        </.link>
        <.link
          :if={@doc_uuid}
          patch={Routes.path("/admin/warehouse/inventory/#{@doc_uuid}/comments")}
          class={["tab", @active_tab == :comments && "tab-active"]}
        >
          {dgettext("default", "Comments")}
          <span :if={@inventory_comment_count > 0} class="badge badge-sm badge-ghost ml-1">
            {@inventory_comment_count}
          </span>
        </.link>
      </div>

      <%!-- Posted info banner (non-admin only: admin can still edit) --%>
      <%= if @posted? and not @admin? and @active_tab == :general do %>
        <div class="alert alert-success">
          <.icon name="hero-check-circle" class="w-5 h-5" />
          <span>
            {dgettext("default", "This stocktake has been conducted and is now read-only.")}
          </span>
        </div>
      <% end %>

      <%!-- Tab: General --%>
      <%= if @active_tab == :general do %>
        <%= if @editable? do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4 flex flex-col gap-3">
              <div class="flex flex-wrap items-center gap-4">
                <%!-- Track value toggle --%>
                <label class="flex items-center gap-2 cursor-pointer">
                  <span class="text-sm font-medium">{dgettext("default", "Track value")}</span>
                  <input
                    type="checkbox"
                    class="toggle toggle-sm toggle-primary"
                    phx-click="toggle_track_value"
                    checked={@track_value}
                  />
                </label>
              </div>
              <%!-- Note --%>
              <div>
                <form phx-change="set_note" phx-submit="set_note">
                  <input
                    type="text"
                    id="inv-note-input"
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

        <%!-- Document info --%>
        <%= if @doc do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4">
              <dl class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-sm">
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Number")}</dt>
                  <dd class="mt-0.5">{@doc.number}</dd>
                </div>
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Status")}</dt>
                  <dd class="mt-0.5">
                    <span class={[
                      "badge badge-sm",
                      @doc.status == "posted" && "badge-success",
                      @doc.status == "draft" && "badge-warning"
                    ]}>
                      {@doc.status}
                    </span>
                  </dd>
                </div>
                <%= if @doc.inserted_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Created")}
                    </dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@doc.inserted_at, "%Y-%m-%d %H:%M")}
                    </dd>
                  </div>
                <% end %>
                <%= if @doc.posted_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Conducted at")}
                    </dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@doc.posted_at, "%Y-%m-%d %H:%M")}
                    </dd>
                  </div>
                <% end %>
                <div>
                  <dt class="text-base-content/60 font-medium">
                    {dgettext("default", "Warehouse (location)")}
                  </dt>
                  <dd class="mt-0.5">
                    <%= if @location_name do %>
                      {@location_name}
                    <% else %>
                      <span class="text-base-content/40">{dgettext("default", "— not set —")}</span>
                    <% end %>
                  </dd>
                </div>
              </dl>

              <%!-- Responsibility fields --%>
              <div class="divider my-1"></div>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-sm">
                <.responsibility_field
                  label={dgettext("default", "Responsible")}
                  field_name="performed_by_uuid"
                  selected_uuid={@doc.performed_by_uuid}
                  admin?={@admin?}
                  selectable_users={@selectable_users}
                />
                <.responsibility_field
                  label={dgettext("default", "Creator")}
                  field_name="created_by_uuid"
                  selected_uuid={@doc.created_by_uuid}
                  admin?={@admin?}
                  selectable_users={@selectable_users}
                />
              </div>
            </div>
          </div>
        <% end %>
      <% end %>

      <%!-- Tab: Items --%>
      <%= if @active_tab == :items do %>
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-center justify-between gap-2 mb-2">
              <h2 class="card-title text-base">
                {dgettext("default", "Count sheet")}
                <span
                  :if={@track_value}
                  class="ml-2 text-sm font-normal text-base-content/50 tabular-nums"
                >
                  {dgettext("default", "Total")}: <.currency_compact amount={@items_value_total} currency="EUR" />
                </span>
              </h2>
              <%!-- Add item button (draft or admin on posted) — in the header row --%>
              <%= if @editable? do %>
                <button type="button" phx-click="open_add_picker" class="btn btn-primary btn-sm">
                  <.icon name="hero-plus" class="w-4 h-4" />
                  {dgettext("default", "Add item")}
                </button>
              <% end %>
            </div>
            <WarehouseBrowser.count_sheet
              lines={@lines}
              track_value={@track_value}
              names={@names}
              stock_map={@stock_map}
              locale={@locale}
              editable={@editable?}
            />
          </div>
        </div>

        <%!-- Add item modal --%>
        <.modal
          show={@show_add_picker_modal}
          on_close="close_add_picker"
          max_width="3xl"
          max_height="80vh"
        >
          <:title>{dgettext("default", "Add item")}</:title>
          <%!-- Mode toggles row --%>
          <div class="flex flex-wrap items-center justify-between gap-3 mb-3">
            <%!-- Add mode: one / many --%>
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
            <%!-- Search mode: list / tree --%>
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
                  {dgettext("default", "Files are not available for this inventory yet.")}
                </div>
              <% true -> %>
                <.live_component
                  module={PhoenixKitWeb.Components.MediaBrowser}
                  id={"media-browser-inventory-#{@doc_uuid}"}
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
                kind={:inventory}
                resource_uuid={@doc_uuid}
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
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Builds the catalogue_summaries list: [{catalogue: catalogue}] for each
  # active catalogue. Used to populate the add_picker tree.
  defp load_catalogue_summaries(catalogues) do
    Enum.map(catalogues, fn catalogue -> %{catalogue: catalogue} end)
  end

  # Lazily loads and caches category metadata for a catalogue when first expanded.
  defp ensure_catalogue_categories_loaded(socket, catalogue_uuid) do
    if Map.has_key?(socket.assigns.loaded_categories, catalogue_uuid) do
      socket
    else
      summary = Catalogue.category_summary_for_catalogue(catalogue_uuid)

      # Build the category list: real categories + a nil entry if uncategorized items exist
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

  # Lazily loads and caches items for a category (or uncategorized) when first expanded.
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

  # Focuses the "Counted" input of the row at `index` (client-side, after the
  # modal closes) via a window event handled in app.js.
  defp focus_counted_input(socket, nil), do: socket

  defp focus_counted_input(socket, index) do
    push_event(socket, "inv-focus-counted", %{id: "counted-input-#{index}"})
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
        stock_entry = Map.get(socket.assigns.stock_map, item_uuid)

        unit_value =
          (stock_entry && stock_entry.unit_value) ||
            StockLedger.to_decimal_or_nil(item.base_price)

        new_line = %{
          "item_uuid" => item_uuid,
          "name" => WarehouseBrowser.localized_name(item, locale),
          "sku" => item.sku,
          "category_uuid" => item.category_uuid,
          "catalogue_uuid" => item.catalogue_uuid,
          "unit" => item.unit,
          "counted_quantity" => Decimal.new("0"),
          "unit_value" => unit_value
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

    catalogue_uuids =
      lines |> Enum.map(& &1["catalogue_uuid"]) |> Enum.filter(& &1) |> Enum.uniq()

    category_uuids = lines |> Enum.map(& &1["category_uuid"]) |> Enum.filter(& &1) |> Enum.uniq()

    items =
      if item_uuids == [],
        do: [],
        else: Catalogue.list_items_by_uuids(item_uuids)

    item_names =
      Map.new(items, fn item ->
        {item.uuid, WarehouseBrowser.localized_name(item, locale)}
      end)

    catalogues =
      if catalogue_uuids == [] do
        []
      else
        Catalogue.list_catalogues()
        |> Enum.filter(&(&1.uuid in catalogue_uuids))
      end

    catalogue_names =
      Map.new(catalogues, fn cat ->
        {cat.uuid,
         WarehouseBrowser.localized_name(cat, locale) |> WarehouseBrowser.strip_prefix()}
      end)

    wanted_category_uuids = MapSet.new(category_uuids)

    categories =
      Enum.flat_map(catalogue_uuids, fn cat_uuid ->
        Catalogue.list_categories_for_catalogue(cat_uuid)
        |> Enum.filter(&MapSet.member?(wanted_category_uuids, &1.uuid))
      end)

    category_names =
      Map.new(categories, fn cat ->
        {cat.uuid, WarehouseBrowser.localized_name(cat, locale)}
      end)

    Map.merge(item_names, Map.merge(catalogue_names, category_names))
  end

  defp ensure_saved(
         %PhoenixKitWarehouse.InventoryDocument{status: "draft"} = doc,
         attrs,
         _user_uuid
       ) do
    Inventories.update_draft(doc, attrs)
  end

  defp ensure_saved(%PhoenixKitWarehouse.InventoryDocument{} = doc, _attrs, _user_uuid) do
    {:ok, doc}
  end

  # Produces a compact change-map comparing submitted attrs vs current doc fields.
  # Only includes fields that actually changed.
  defp diff_doc_changes(doc, attrs) do
    %{}
    |> maybe_add_scalar_change(:note, doc.note || "", attrs[:note] || attrs["note"] || "")
    |> maybe_add_scalar_change(
      :track_value,
      doc.track_value,
      Map.get(attrs, :track_value, Map.get(attrs, "track_value", doc.track_value))
    )
    |> maybe_add_lines_change(doc.lines, attrs[:lines] || attrs["lines"] || [])
  end

  defp maybe_add_scalar_change(acc, _key, same, same), do: acc

  defp maybe_add_scalar_change(acc, key, from, to) do
    Map.put(acc, key, %{from: to_string(from), to: to_string(to)})
  end

  defp maybe_add_responsibility_change(acc, _key, same, same), do: acc

  defp maybe_add_responsibility_change(acc, key, from, to) do
    Map.put(acc, key, {from, to})
  end

  defp maybe_add_lines_change(acc, old_lines, new_lines) do
    if length(old_lines) != length(new_lines) do
      Map.put(acc, :line_count, %{from: length(old_lines), to: length(new_lines)})
    else
      acc
    end
  end

  defp present_uuids(lines) do
    lines
    |> Enum.map(& &1["item_uuid"])
    |> Enum.filter(& &1)
    |> MapSet.new()
  end

  defp clamp_non_negative(%Decimal{} = d) do
    zero = Decimal.new("0")
    if Decimal.compare(d, zero) == :lt, do: zero, else: d
  end

  # Returns user email for display; falls back to uuid fragment when not found.
  defp user_display_name(nil, _users), do: dgettext("default", "— not set —")

  defp user_display_name(uuid, users) do
    case Enum.find(users, &(&1.uuid == uuid)) do
      %{email: email} -> email
      nil -> String.slice(uuid, 0, 8) <> "…"
    end
  end

  # ---------------------------------------------------------------------------
  # Function component: responsibility field (admin = select, non-admin = span)
  # Extracted to enable unit testing of both rendering branches independently.
  # ---------------------------------------------------------------------------

  @doc false
  attr(:label, :string, required: true)
  attr(:field_name, :string, required: true)
  attr(:selected_uuid, :string, default: nil)
  attr(:admin?, :boolean, required: true)
  attr(:selectable_users, :list, required: true)

  def responsibility_field(assigns) do
    ~H"""
    <div>
      <label class="text-base-content/60 font-medium block mb-1">
        {@label}
      </label>
      <%= if @admin? do %>
        <form phx-change="set_responsibility" onsubmit="return false">
          <select
            name={@field_name}
            class="select select-sm select-bordered w-full"
          >
            <option value="">{dgettext("default", "— not set —")}</option>
            <%= for user <- @selectable_users do %>
              <option value={user.uuid} selected={@selected_uuid == user.uuid}>
                {user.email}
              </option>
            <% end %>
          </select>
        </form>
      <% else %>
        <span class="text-base-content/80">
          {user_display_name(@selected_uuid, @selectable_users)}
        </span>
      <% end %>
    </div>
    """
  end
end
