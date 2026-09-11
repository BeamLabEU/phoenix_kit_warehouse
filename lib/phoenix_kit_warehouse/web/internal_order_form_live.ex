defmodule PhoenixKitWarehouse.Web.InternalOrderFormLive do
  @moduledoc """
  LiveView for creating and editing internal orders.

  Handles:
  - `:new`      — creates a draft and push_navigate to :edit path.
  - `:edit`     — loads an existing order; :general tab.
  - `:items`    — lines editor (draft only for adding/editing quantities).

  Uses the admin header-breadcrumb pattern: `use PhoenixKitWeb, :live_view` +
  a `self_wrapped_layout` on_mount wrapping render/1 in
  `<LayoutWrapper.app_layout>` (title in the global admin header). No streams.
  All navigation paths wrapped in `PhoenixKit.Utils.Routes.path/1`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWarehouse.Gettext
  use PhoenixKitComments.Embed
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.MediaBrowser

  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.Components.ItemSelectorModal
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.Comments
  alias PhoenixKitWarehouse.DocRefs
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.StorageFolders
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Web.Components.{CommentsPanel, RelatedDocuments, WarehouseBrowser}

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    locale = socket.assigns[:current_locale] || Gettext.get_locale()

    scope = socket.assigns[:phoenix_kit_current_scope]
    current_user = scope && Scope.user(scope)
    admin? = !!(scope && Scope.can_access_admin_area?(scope))

    comments_available? = Comments.available?()

    socket =
      socket
      |> assign(:locale, locale)
      |> assign(:current_user, current_user)
      |> assign(:admin?, admin?)
      |> assign(:show_item_selector, false)
      |> assign(:order, nil)
      |> assign(:lines, [])
      |> assign(:note, "")
      |> assign(:names, %{})
      |> assign(:active_tab, :general)
      |> assign(:files_scope_folder_uuid, nil)
      |> assign(:files_folder_loading, false)
      |> assign(:comments_available?, comments_available?)
      |> assign(:comment_count, 0)
      |> assign(:comments_subscribed?, false)
      |> assign(:location_name, nil)
      |> assign(:sub_order_ref, nil)
      |> assign(:child_supplier_order_refs, [])
      |> assign(:child_goods_issue_refs, [])
      |> assign(:page_title, dgettext("default", "Internal Order"))
      |> assign(:show_source_picker, false)
      |> assign(:picker_purpose, :import)
      |> assign(:source_picker_candidates, [])
      |> assign(:source_picker_selected, MapSet.new())
      |> assign(:source_picker_selected_meta, %{})
      |> assign(:source_picker_query, "")
      |> assign(:source_refs, [])
      |> MediaBrowser.setup_uploads()

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
        socket = load_order_into_socket(socket, uuid, locale)

        {:noreply,
         socket |> assign(:active_tab, :general) |> maybe_subscribe_and_refresh_comments()}

      :items ->
        uuid = params["uuid"]
        socket = load_order_into_socket(socket, uuid, locale)

        {:noreply,
         socket |> assign(:active_tab, :items) |> maybe_subscribe_and_refresh_comments()}

      :files ->
        uuid = params["uuid"]
        socket = load_order_into_socket(socket, uuid, locale)

        {:noreply,
         socket
         |> assign(:active_tab, :files)
         |> maybe_start_files_folder_resolution()
         |> maybe_subscribe_and_refresh_comments()}

      :comments ->
        uuid = params["uuid"]
        socket = load_order_into_socket(socket, uuid, locale)

        {:noreply,
         socket
         |> assign(:active_tab, :comments)
         |> maybe_subscribe_and_refresh_comments()}

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_params_new(socket, _locale) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    current_user = scope && Scope.user(scope)
    user_uuid = current_user && current_user.uuid

    attrs = %{
      lines: [],
      created_by_uuid: user_uuid
    }

    case InternalOrders.create_internal_order(attrs) do
      {:ok, order} ->
        {:noreply,
         push_navigate(socket,
           to: Routes.path("/admin/warehouse/internal-orders/#{order.uuid}")
         )}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("default", "Failed to create draft internal order"))
         |> push_navigate(to: Routes.path("/admin/warehouse/internal-orders"))}
    end
  end

  defp load_order_into_socket(socket, uuid, locale) do
    order = InternalOrders.get_internal_order!(uuid)
    same_order? = match?(%{uuid: ^uuid}, socket.assigns[:order])

    sub_order_ref = DocRefs.sub_order_ref(sub_order_uuid_of(order))
    child_supplier_order_refs = load_child_supplier_order_refs(uuid)
    child_goods_issue_refs = load_child_goods_issue_refs(uuid)

    source_refs = DocRefs.refs_for(order.source_refs || [])

    socket =
      socket
      |> assign(:order, order)
      |> assign(:location_name, resolve_location_name(order.location_uuid))
      |> assign(:sub_order_ref, sub_order_ref)
      |> assign(:child_supplier_order_refs, child_supplier_order_refs)
      |> assign(:child_goods_issue_refs, child_goods_issue_refs)
      |> assign(:source_refs, source_refs)
      |> assign(
        :page_title,
        dgettext("default", "Internal Order #%{number}", number: order.number)
      )

    if same_order?, do: socket, else: assign_edit_buffer(socket, order, locale)
  end

  defp load_child_supplier_order_refs(internal_order_uuid) do
    DocRefs.supplier_order_refs_for_internal_order(internal_order_uuid)
  end

  defp load_child_goods_issue_refs(internal_order_uuid) do
    DocRefs.goods_issue_refs_for_internal_order(internal_order_uuid)
  end

  defp assign_edit_buffer(socket, order, locale) do
    socket
    |> assign(:lines, order.lines)
    |> assign(:note, order.note || "")
    |> assign(:names, build_names_map(order.lines, locale))
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
  # Item selector modal handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("open_item_selector", _params, socket) do
    posted? = socket.assigns.order && socket.assigns.order.status == "posted"

    if posted? do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :show_item_selector, true)}
    end
  end

  # ---------------------------------------------------------------------------
  # Source picker modal handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("open_source_picker", _params, socket) do
    candidates = InternalOrders.list_import_candidates()

    socket =
      socket
      |> assign(:picker_purpose, :import)
      |> assign(:show_source_picker, true)
      |> assign(:source_picker_candidates, candidates)
      |> assign(:source_picker_selected, MapSet.new())
      |> assign(:source_picker_selected_meta, %{})
      |> assign(:source_picker_query, "")

    {:noreply, socket}
  end

  @doc false
  # Opens the picker in "manual link" mode — attaches a traceability
  # reference without touching lines. Unlike "open_source_picker" (line
  # import), this works on both draft and posted internal orders.
  @impl true
  def handle_event("open_link_picker", _params, socket) do
    candidates = InternalOrders.list_import_candidates()

    socket =
      socket
      |> assign(:picker_purpose, :link)
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
        candidate =
          Enum.find(socket.assigns.source_picker_candidates, &(&1.uuid == uuid))

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
  def handle_event(
        "source_picker_confirm",
        _params,
        %{assigns: %{picker_purpose: :import}} = socket
      ) do
    order = socket.assigns.order
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid
    meta = socket.assigns.source_picker_selected_meta

    selected_refs =
      meta
      |> Enum.map(fn {uuid, type} -> %{"type" => type, "uuid" => uuid} end)

    case InternalOrders.import_from_sources(order, selected_refs, user_uuid) do
      {:ok, updated_order} ->
        locale = socket.assigns.locale
        source_refs = DocRefs.refs_for(updated_order.source_refs || [])

        socket =
          socket
          |> assign(:order, updated_order)
          |> assign(:lines, updated_order.lines)
          |> assign(:names, build_names_map(updated_order.lines, locale))
          |> assign(:source_refs, source_refs)
          |> assign(:show_source_picker, false)
          |> assign(:source_picker_selected, MapSet.new())
          |> assign(:source_picker_selected_meta, %{})
          |> assign(:source_picker_query, "")
          |> put_flash(:info, dgettext("default", "Lines imported"))

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:show_source_picker, false)
         |> put_flash(:error, dgettext("default", "Failed to import lines"))}
    end
  end

  def handle_event("source_picker_confirm", _params, socket) do
    order = socket.assigns.order
    meta = socket.assigns.source_picker_selected_meta

    result =
      Enum.reduce_while(meta, {:ok, order}, fn {uuid, type}, {:ok, current_order} ->
        case InternalOrders.add_source_ref(current_order, type, uuid) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, updated_order} ->
        source_refs = DocRefs.refs_for(updated_order.source_refs || [])

        socket =
          socket
          |> assign(:order, updated_order)
          |> assign(:source_refs, source_refs)
          |> assign(:show_source_picker, false)
          |> assign(:source_picker_selected, MapSet.new())
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
    order = socket.assigns.order

    case InternalOrders.remove_source_ref(order, type, uuid) do
      {:ok, updated_order} ->
        socket =
          socket
          |> assign(:order, updated_order)
          |> assign(:source_refs, DocRefs.refs_for(updated_order.source_refs || []))

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to remove link"))}
    end
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
  def handle_event("set_required_qty", params, socket) do
    index = String.to_integer(params["index"])
    raw = params["required_quantity"] || "0"

    lines =
      socket.assigns.lines
      |> List.update_at(index, fn line ->
        Map.put(line, "required_quantity", raw)
      end)

    {:noreply, assign(socket, :lines, lines)}
  end

  @impl true
  def handle_event("set_note", %{"note" => note}, socket) do
    {:noreply, assign(socket, :note, note)}
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

    case socket.assigns.order do
      %PhoenixKitWarehouse.InternalOrder{status: "draft"} = order ->
        case InternalOrders.update_draft(order, attrs) do
          {:ok, updated_order} ->
            {:noreply,
             socket
             |> assign(:order, updated_order)
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
  # Conduct (post)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("conduct", _params, socket) do
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid

    save_attrs = %{
      note: socket.assigns.note,
      lines: socket.assigns.lines
    }

    order = socket.assigns.order

    with {:ok, saved_order} <- ensure_saved(order, save_attrs),
         {:ok, _posted_order} <- InternalOrders.post_internal_order(saved_order, user_uuid) do
      {:noreply,
       socket
       |> put_flash(:info, dgettext("default", "Internal order conducted"))
       |> push_navigate(to: Routes.path("/admin/warehouse/internal-orders"))}
    else
      {:error, :not_draft} ->
        {:noreply,
         put_flash(socket, :error, dgettext("default", "Document is already conducted"))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, dgettext("default", "Failed to conduct internal order"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Save correction (note-only, admin-only)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_correction", _params, %{assigns: %{admin?: false}} = socket) do
    {:noreply, put_flash(socket, :error, dgettext("default", "Not authorized"))}
  end

  def handle_event("save_correction", _params, socket) do
    order = socket.assigns.order
    attrs = %{note: socket.assigns.note}

    case InternalOrders.correct_internal_order(order, attrs) do
      {:ok, corrected_order} ->
        {:noreply,
         socket
         |> assign(:order, corrected_order)
         |> put_flash(:info, dgettext("default", "Correction saved"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to save correction"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Generate supplier orders (posted only)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("generate_supplier_orders", _params, socket) do
    order = socket.assigns.order

    case order do
      %PhoenixKitWarehouse.InternalOrder{status: "posted"} ->
        current_user = socket.assigns.current_user
        user_uuid = current_user && current_user.uuid

        case SupplierOrders.generate_from_internal_order(order, user_uuid) do
          {:ok, %{supplier_orders: created, unassigned_lines: unassigned}} ->
            n = length(created)
            m = length(unassigned)

            msg =
              cond do
                n > 0 and m > 0 ->
                  dgettext(
                    "default",
                    "Generated %{n} supplier order(s). %{m} line(s) could not be assigned to a supplier.",
                    n: n,
                    m: m
                  )

                n > 0 ->
                  dgettext("default", "Generated %{n} supplier order(s).", n: n)

                m > 0 ->
                  dgettext(
                    "default",
                    "No supplier orders created. %{m} line(s) could not be assigned (0 or multiple suppliers).",
                    m: m
                  )

                true ->
                  dgettext("default", "No lines required restocking.")
              end

            socket =
              socket
              |> put_flash(:info, msg)
              |> push_navigate(to: Routes.path("/admin/warehouse/supplier-orders"))

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, dgettext("default", "Failed to generate supplier orders"))}
        end

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("default", "Only posted internal orders can generate supplier orders")
         )}
    end
  end

  # ---------------------------------------------------------------------------
  # Issue to production (posted only)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("issue_to_production", _params, socket) do
    order = socket.assigns.order
    admin? = socket.assigns.admin?

    case order do
      %PhoenixKitWarehouse.InternalOrder{status: "posted"} when admin? ->
        current_user = socket.assigns.current_user
        user_uuid = current_user && current_user.uuid

        case GoodsIssues.create_from_internal_order(order, user_uuid) do
          {:ok, goods_issue} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               dgettext("default", "Goods issue #%{number} created", number: goods_issue.number)
             )
             |> push_navigate(
               to: Routes.path("/admin/warehouse/goods-issues/#{goods_issue.uuid}")
             )}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, dgettext("default", "Failed to create goods issue"))}
        end

      %PhoenixKitWarehouse.InternalOrder{status: "posted"} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Not authorized"))}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("default", "Only posted internal orders can create goods issues")
         )}
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
      case socket.assigns.order do
        %{uuid: uuid} when not is_nil(uuid) ->
          Comments.count(:internal_order, uuid)

        _ ->
          0
      end

    {:noreply, assign(socket, :comment_count, count)}
  end

  def handle_info({PhoenixKitWeb.Components.MediaBrowser, _action, _payload} = msg, socket) do
    MediaBrowser.handle_parent_info(msg, socket)
  end

  # ItemSelectorModal contract (PhoenixKitCatalogue.Web.Components.ItemSelectorModal):
  # fired on Confirm with the batch of picks (uuid + Decimal qty); each pick
  # becomes a new draft line seeded with the picked quantity — re-adding an
  # already-present item is a no-op. `posted?` isn't a socket assign (it's
  # computed in render/1), so it's re-derived here, same as add_position did.
  def handle_info({:items_selected, %{picks: picks}}, socket) do
    posted? = socket.assigns.order && socket.assigns.order.status == "posted"

    socket =
      if posted? do
        socket
      else
        add_picks_to_lines(socket, picks)
      end

    {:noreply, assign(socket, :show_item_selector, false)}
  end

  def handle_info({:item_selector_closed, %{id: _}}, socket) do
    {:noreply, assign(socket, :show_item_selector, false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:posted?, assigns.order && assigns.order.status == "posted")
      |> assign(:order_uuid, assigns.order && assigns.order.uuid)

    assigns = assign_new(assigns, :sub_order_ref, fn -> nil end)
    assigns = assign_new(assigns, :child_supplier_order_refs, fn -> [] end)
    assigns = assign_new(assigns, :child_goods_issue_refs, fn -> [] end)
    assigns = assign_new(assigns, :source_refs, fn -> [] end)

    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      current_path={
        assigns[:url_path] || assigns[:current_path] ||
          Routes.path("/admin/warehouse/internal-orders")
      }
      current_locale={assigns[:current_locale]}
    >
    <div class="flex flex-col mx-auto max-w-none sm:px-4 py-2 sm:py-6 gap-4">
      <div class="flex flex-wrap items-center justify-end gap-2">
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
            phx-click="conduct"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-check" class="w-4 h-4" /> {dgettext("default", "Conduct")}
          </button>
        <% end %>
        <%!-- Posted + admin: note correction + badge --%>
        <%= if @posted? and @admin? and @active_tab == :general do %>
          <button
            type="button"
            phx-click="save_correction"
            class="btn btn-ghost btn-sm"
          >
            {dgettext("default", "Save correction")}
          </button>
        <% end %>
        <%!-- Posted badge (always shown when posted) --%>
        <%= if @posted? do %>
          <span class="badge badge-success badge-lg">{dgettext("default", "Conducted")}</span>
        <% end %>
        <%!-- Generate supplier orders (posted only) --%>
        <%= if @posted? do %>
          <button
            type="button"
            phx-click="generate_supplier_orders"
            class="btn btn-secondary btn-sm"
          >
            <.icon name="hero-truck" class="w-4 h-4" /> {dgettext(
              "default",
              "Generate supplier orders"
            )}
          </button>
        <% end %>
        <%!-- Issue to production (posted only) --%>
        <%= if @posted? do %>
          <button
            type="button"
            phx-click="issue_to_production"
            class="btn btn-accent btn-sm"
          >
            <.icon name="hero-arrow-up-on-square" class="w-4 h-4" /> {dgettext(
              "default",
              "Issue to production"
            )}
          </button>
        <% end %>
      </div>

      <%!-- Tab navigation --%>
      <div class="tabs tabs-border">
        <.link
          patch={Routes.path("/admin/warehouse/internal-orders/#{@order_uuid}")}
          class={["tab", @active_tab == :general && "tab-active"]}
        >
          {dgettext("default", "General")}
        </.link>
        <.link
          :if={@order_uuid}
          patch={Routes.path("/admin/warehouse/internal-orders/#{@order_uuid}/items")}
          class={["tab", @active_tab == :items && "tab-active"]}
        >
          {dgettext("default", "Items")}
        </.link>
        <.link
          :if={@order_uuid}
          patch={Routes.path("/admin/warehouse/internal-orders/#{@order_uuid}/files")}
          class={["tab", @active_tab == :files && "tab-active"]}
        >
          {dgettext("default", "Files")}
        </.link>
        <.link
          :if={@order_uuid}
          patch={Routes.path("/admin/warehouse/internal-orders/#{@order_uuid}/comments")}
          class={["tab", @active_tab == :comments && "tab-active"]}
        >
          {dgettext("default", "Comments")}
          <span :if={@comment_count > 0} class="badge badge-sm badge-ghost ml-1">
            {@comment_count}
          </span>
        </.link>
      </div>

      <%!-- Posted info banner (non-admin only) --%>
      <%= if @posted? and not @admin? do %>
        <div class="alert alert-success">
          <.icon name="hero-check-circle" class="w-5 h-5" />
          <span>{dgettext("default", "This internal order has been conducted and is now read-only.")}</span>
        </div>
      <% end %>

      <%!-- Tab: General --%>
      <%= if @active_tab == :general do %>
        <%= if !@posted? do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4 flex flex-col gap-3">
              <div>
                <form phx-change="set_note" phx-submit="set_note">
                  <input
                    type="text"
                    id="io-note-input"
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

        <%= if @order do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4">
              <dl class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-sm">
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Number")}</dt>
                  <dd class="mt-0.5 font-mono">#IO-{@order.number}</dd>
                </div>
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Status")}</dt>
                  <dd class="mt-0.5">
                    <span class={[
                      "badge badge-sm",
                      @order.status == "posted" && "badge-success",
                      @order.status == "draft" && "badge-warning"
                    ]}>
                      {@order.status}
                    </span>
                  </dd>
                </div>
                <%= if @order.inserted_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Created")}
                    </dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@order.inserted_at, "%Y-%m-%d %H:%M")}
                    </dd>
                  </div>
                <% end %>
                <%= if @order.posted_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Conducted at")}
                    </dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@order.posted_at, "%Y-%m-%d %H:%M")}
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
                <%= if @sub_order_ref do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">{dgettext("default", "Sub-Order")}</dt>
                    <dd class="mt-0.5">
                      <.link
                        navigate={@sub_order_ref.path}
                        class="link link-primary font-mono text-sm"
                      >
                        {@sub_order_ref.label}
                      </.link>
                    </dd>
                  </div>
                <% end %>
                <%= if @order.note && @posted? do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Note")}
                    </dt>
                    <dd class="mt-0.5">{@order.note}</dd>
                  </div>
                <% end %>
              </dl>
              <%!-- Related documents (imported-from upstream + spawned downstream) --%>
              <RelatedDocuments.related_documents
                upstream={@source_refs}
                downstream={@child_supplier_order_refs ++ @child_goods_issue_refs}
                upstream_label={dgettext("default", "Imported from")}
                downstream_label={dgettext("default", "Related documents")}
              />
              <%!-- Note edit on posted doc (admin only) --%>
              <%= if @posted? and @admin? do %>
                <div class="divider my-1"></div>
                <div class="text-sm">
                  <label class="text-base-content/60 font-medium block mb-1">
                    {dgettext("default", "Note")}
                  </label>
                  <form phx-change="set_note" phx-submit="set_note">
                    <input
                      type="text"
                      id="io-note-posted-input"
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
                  {dgettext("default", "Files are not available for this internal order yet.")}
                </div>
              <% true -> %>
                <.live_component
                  module={PhoenixKitWeb.Components.MediaBrowser}
                  id={"media-browser-io-#{@order_uuid}"}
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
                kind={:internal_order}
                resource_uuid={@order_uuid}
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
              <%= if !@posted? do %>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    phx-click="open_source_picker"
                    class="btn btn-outline btn-sm"
                  >
                    <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
                    {dgettext("default", "Import from order")}
                  </button>
                  <button type="button" phx-click="open_item_selector" class="btn btn-primary btn-sm">
                    <.icon name="hero-plus" class="w-4 h-4" />
                    {dgettext("default", "Add item")}
                  </button>
                </div>
              <% end %>
            </div>
            <.internal_order_lines_table
              lines={@lines}
              names={@names}
              posted?={@posted?}
              locale={@locale}
            />
          </div>
        </div>

        <.live_component
          :if={@show_item_selector}
          module={ItemSelectorModal}
          id="internal-order-item-selector"
          scope={%{statuses: ["active"]}}
          selected={selected_items(@lines)}
          locale={@locale}
          qty_precision={6}
        />
      <% end %>

      <%!-- Source picker modal: import lines from an order, or attach a manual link --%>
      <WarehouseBrowser.source_picker
        id="io-source-picker"
        show={@show_source_picker}
        title={picker_title(@picker_purpose)}
        on_close="close_source_picker"
        candidates={@source_picker_candidates}
        selected_uuids={@source_picker_selected}
        search_query={@source_picker_query}
      />
    </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp picker_title(:import), do: dgettext("default", "Import from order")
  defp picker_title(:link), do: dgettext("default", "Attach customer order")

  # ---------------------------------------------------------------------------
  # Function components
  # ---------------------------------------------------------------------------

  attr(:lines, :list, required: true)
  attr(:names, :map, required: true)
  attr(:posted?, :boolean, required: true)
  attr(:locale, :string, required: true)

  defp internal_order_lines_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>{dgettext("default", "Item")}</th>
            <th class="w-16 text-center">{dgettext("default", "Unit")}</th>
            <th class="w-32 text-center">{dgettext("default", "Required qty")}</th>
            <%= if !@posted? do %>
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
                <%= if @posted? do %>
                  <span class="tabular-nums">{fmt_stored_qty(line["required_quantity"])}</span>
                <% else %>
                  <form
                    id={"io-qty-form-#{index}"}
                    phx-change="set_required_qty"
                    phx-submit="set_required_qty"
                  >
                    <input type="hidden" name="index" value={index} />
                    <input
                      type="number"
                      id={"io-qty-#{index}"}
                      name="required_quantity"
                      min="0"
                      step="any"
                      value={line["required_quantity"] || ""}
                      placeholder="0"
                      class="input input-sm w-24 text-center"
                      phx-debounce="blur"
                      phx-hook="InvEnterBlur"
                    />
                  </form>
                <% end %>
              </td>
              <%= if !@posted? do %>
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
        order = socket.assigns.order
        user_uuid = socket.assigns.current_user && socket.assigns.current_user.uuid

        Task.Supervisor.start_child(PhoenixKitWarehouse.TaskSupervisor, fn ->
          result = StorageFolders.ensure_for_internal_order(order, user_uuid)
          send(lv_pid, {:files_folder_result, result})
        end)

        assign(socket, :files_folder_loading, true)
    end
  end

  defp maybe_subscribe_and_refresh_comments(socket) do
    order = socket.assigns.order

    if connected?(socket) and order do
      socket =
        if socket.assigns.comments_subscribed? do
          socket
        else
          Comments.subscribe(:internal_order, [order.uuid])
          assign(socket, :comments_subscribed?, true)
        end

      count = Comments.count(:internal_order, order.uuid)
      assign(socket, :comment_count, count)
    else
      socket
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # ItemSelectorModal confirm: one pick per selected item (uuid + Decimal
  # qty). Each lands as a new draft line, seeded with the picked quantity;
  # re-adding an already-present item is a no-op (dedup by item_uuid), same
  # as the add_picker it replaces.
  defp add_picks_to_lines(socket, picks) do
    Enum.reduce(picks, socket, fn pick, socket ->
      add_item_to_lines(socket, pick.uuid, pick.qty)
    end)
  end

  defp add_item_to_lines(socket, item_uuid, qty) do
    lines = socket.assigns.lines
    locale = socket.assigns.locale

    already_present? = Enum.any?(lines, &(&1["item_uuid"] == item_uuid))

    lines =
      if already_present? do
        lines
      else
        case Catalogue.get_item(item_uuid) do
          nil ->
            lines

          item ->
            new_line = %{
              "item_uuid" => item_uuid,
              "name" => WarehouseBrowser.localized_name(item, locale),
              "sku" => item.sku,
              "catalogue_uuid" => item.catalogue_uuid,
              "category_uuid" => item.category_uuid,
              "unit" => item.unit,
              "required_quantity" => StockLedger.format_quantity(qty)
            }

            lines ++ [new_line]
        end
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

  defp ensure_saved(%PhoenixKitWarehouse.InternalOrder{status: "draft"} = order, attrs) do
    InternalOrders.update_draft(order, attrs)
  end

  defp ensure_saved(%PhoenixKitWarehouse.InternalOrder{} = order, _attrs) do
    {:ok, order}
  end

  # A posted document's quantity is read straight out of its jsonb line, where
  # it may still carry the `numeric(_, 6)` padding that a pre-normalisation
  # write left behind ("5.000000"). The editable branch renders through an
  # input, which is trimmed on the way in; this read-only branch had no such
  # step, so the same number read differently depending on whether the document
  # was posted before or after quantities started being normalised on write —
  # and on a posted document nobody can edit the value to "fix" the display.
  # A blank stays an em dash: `format_quantity/1` would turn a missing value
  # into "0", a claim the document does not make.
  defp fmt_stored_qty(nil), do: "—"
  defp fmt_stored_qty(""), do: "—"
  defp fmt_stored_qty(value), do: StockLedger.format_quantity(value)

  # ItemSelectorModal's `selected` attr: %{uuid => qty} for every line already
  # on the order, so an already-added item shows in the modal's tray instead
  # of being re-added as a duplicate.
  defp selected_items(lines) do
    Enum.reduce(lines, %{}, fn
      %{"item_uuid" => uuid} = line, acc when is_binary(uuid) ->
        Map.put(acc, uuid, StockLedger.to_decimal(line["required_quantity"]))

      _, acc ->
        acc
    end)
  end

  defp sub_order_uuid_of(%{source_refs: refs}) do
    Enum.find_value(refs || [], fn
      %{"type" => "sub_order", "uuid" => uuid} -> uuid
      _ -> nil
    end)
  end
end
