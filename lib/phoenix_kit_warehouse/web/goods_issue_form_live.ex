defmodule PhoenixKitWarehouse.Web.GoodsIssueFormLive do
  @moduledoc """
  LiveView for creating and editing goods issues.

  Handles:
  - `:new`      — creates an empty draft and push_navigates to `:edit`.
  - `:edit`     — loads an existing issue; :general tab.
  - `:lines`    — lines tab: editable issued_quantity with current on-hand shown.
                  Draft-only: "Import from internal order" button opens source_picker modal.
  - `:files`    — MediaBrowser; storage folder resolved asynchronously.
  - `:comments` — goods issue comments thread.

  Uses the admin-chrome pattern: `use PhoenixKitWeb, :live_view` +
  `<.admin_page_header>`. No `<Layouts.app>`, no streams.
  All navigation paths wrapped in `PhoenixKit.Utils.Routes.path/1`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWarehouse.Gettext
  use PhoenixKitComments.Embed

  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.DocRefs
  alias PhoenixKitWarehouse.Comments
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.StorageFolders
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.Web.Components.{CommentsPanel, WarehouseBrowser}

  alias PhoenixKit.Utils.Routes

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
      |> assign(:issue, nil)
      |> assign(:lines, [])
      |> assign(:note, "")
      |> assign(:active_tab, :general)
      |> assign(:files_scope_folder_uuid, nil)
      |> assign(:files_folder_loading, false)
      |> assign(:comments_available?, comments_available?)
      |> assign(:comment_count, 0)
      |> assign(:comments_subscribed?, false)
      |> assign(:location_name, nil)
      |> assign(:sub_order_ref, nil)
      |> assign(:internal_order_ref, nil)
      |> assign(:refs_by_kind, %{})
      |> assign(:page_title, dgettext("default", "Goods Issue"))
      |> assign(:on_hand_map, %{})
      |> assign(:show_io_picker, false)
      |> assign(:picker_purpose, :import)
      |> assign(:io_picker_all_candidates, [])
      |> assign(:io_picker_candidates, [])
      |> assign(:io_picker_selected, [])
      |> assign(:io_picker_selected_meta, %{})
      |> assign(:io_picker_query, "")
      |> assign(:warehouses, StockLedger.list_warehouses())
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
        socket = load_issue_into_socket(socket, uuid)

        {:noreply,
         socket |> assign(:active_tab, :general) |> maybe_subscribe_and_refresh_comments()}

      :lines ->
        uuid = params["uuid"]
        socket = load_issue_into_socket(socket, uuid)

        {:noreply,
         socket
         |> assign(:active_tab, :lines)
         |> load_on_hand_quantities()
         |> maybe_subscribe_and_refresh_comments()}

      :files ->
        uuid = params["uuid"]
        socket = load_issue_into_socket(socket, uuid)

        {:noreply,
         socket
         |> assign(:active_tab, :files)
         |> maybe_start_files_folder_resolution()
         |> maybe_subscribe_and_refresh_comments()}

      :comments ->
        uuid = params["uuid"]
        socket = load_issue_into_socket(socket, uuid)

        {:noreply,
         socket
         |> assign(:active_tab, :comments)
         |> maybe_subscribe_and_refresh_comments()}

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_params_new(socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    current_user = scope && PhoenixKit.Users.Auth.Scope.user(scope)
    user_uuid = current_user && current_user.uuid

    case GoodsIssues.create_goods_issue(%{created_by_uuid: user_uuid}) do
      {:ok, issue} ->
        {:noreply,
         push_navigate(socket,
           to: Routes.path("/admin/warehouse/goods-issues/#{issue.uuid}")
         )}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("default", "Failed to create draft goods issue"))
         |> push_navigate(to: Routes.path("/admin/warehouse/goods-issues"))}
    end
  end

  defp load_issue_into_socket(socket, uuid) do
    issue = GoodsIssues.get_goods_issue!(uuid)
    same_issue? = match?(%{uuid: ^uuid}, socket.assigns[:issue])

    location_name = resolve_location_name(issue.location_uuid)
    sub_order_ref = DocRefs.sub_order_ref(sub_order_uuid_of(issue))
    internal_order_ref = DocRefs.internal_order_ref(issue.internal_order_uuid)

    socket =
      socket
      |> assign(:issue, issue)
      |> assign(:location_name, location_name)
      |> assign(:sub_order_ref, sub_order_ref)
      |> assign(:internal_order_ref, internal_order_ref)
      |> assign(:refs_by_kind, refs_by_kind(issue))
      |> assign(:page_title, dgettext("default", "Goods Issue #%{number}", number: issue.number))

    if same_issue?, do: socket, else: assign_edit_buffer(socket, issue)
  end

  defp assign_edit_buffer(socket, issue) do
    socket
    |> assign(:lines, issue.lines)
    |> assign(:note, issue.note || "")
  end

  defp load_on_hand_quantities(socket) do
    lines = socket.assigns.lines
    item_uuids = lines |> Enum.map(& &1["item_uuid"]) |> Enum.filter(& &1) |> Enum.uniq()
    location_uuid = socket.assigns.issue.location_uuid

    on_hand_map =
      item_uuids
      |> StockLedger.stock_for_items_at_location(location_uuid)
      |> Map.new(&{&1.item_uuid, &1.quantity})

    assign(socket, :on_hand_map, on_hand_map)
  end

  defp maybe_subscribe_and_refresh_comments(socket) do
    issue = socket.assigns.issue

    if connected?(socket) and issue do
      socket =
        if socket.assigns.comments_subscribed? do
          socket
        else
          Comments.subscribe(:goods_issue, [issue.uuid])
          assign(socket, :comments_subscribed?, true)
        end

      count = Comments.count(:goods_issue, issue.uuid)
      assign(socket, :comment_count, count)
    else
      socket
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
        issue = socket.assigns.issue
        user_uuid = socket.assigns.current_user && socket.assigns.current_user.uuid

        Task.Supervisor.start_child(PhoenixKitWarehouse.TaskSupervisor, fn ->
          result = StorageFolders.ensure_for_goods_issue(issue, user_uuid)
          send(lv_pid, {:files_folder_result, result})
        end)

        assign(socket, :files_folder_loading, true)
    end
  end

  # ---------------------------------------------------------------------------
  # Issued quantity editing
  # ---------------------------------------------------------------------------

  # MediaBrowser allows the `:media_files` upload on this parent LiveView
  # (see setup_uploads/1), so its `phx-change="validate"` channel fires here.
  # Absorb it to avoid a FunctionClauseError crash on file upload.
  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("set_issued_qty", params, socket) do
    index = String.to_integer(params["index"])
    raw = params["issued_quantity"] || "0"

    qty = StockLedger.to_decimal(raw) |> clamp_non_negative()

    lines =
      socket.assigns.lines
      |> List.update_at(index, fn line ->
        Map.put(line, "issued_quantity", qty)
      end)

    {:noreply, assign(socket, :lines, lines)}
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
    case socket.assigns.issue do
      %PhoenixKitWarehouse.GoodsIssue{status: "draft"} = issue ->
        with {:ok, updated} <- GoodsIssues.update_draft(issue, %{location_uuid: uuid}) do
          {:noreply,
           socket
           |> assign(:issue, updated)
           |> assign(:location_name, resolve_location_name(updated.location_uuid))
           |> load_on_hand_quantities()
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

    case socket.assigns.issue do
      %PhoenixKitWarehouse.GoodsIssue{status: "draft"} = issue ->
        case GoodsIssues.update_draft(issue, attrs) do
          {:ok, updated_issue} ->
            {:noreply,
             socket
             |> assign(:issue, updated_issue)
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

    issue = socket.assigns.issue

    with {:ok, saved_issue} <- ensure_saved(issue, save_attrs),
         {:ok, _posted_issue} <- GoodsIssues.post_goods_issue(saved_issue, user_uuid) do
      {:noreply,
       socket
       |> put_flash(:info, dgettext("default", "Goods issue posted — stock updated"))
       |> push_navigate(to: Routes.path("/admin/warehouse/goods-issues"))}
    else
      {:error, :not_draft} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Document is already posted"))}

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
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to post goods issue"))}
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
    issue = socket.assigns.issue
    attrs = %{note: socket.assigns.note}

    case GoodsIssues.correct_goods_issue(issue, attrs) do
      {:ok, corrected_issue} ->
        {:noreply,
         socket
         |> assign(:issue, corrected_issue)
         |> put_flash(:info, dgettext("default", "Correction saved"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to save correction"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Source picker: import from internal orders
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("open_io_picker", _params, socket) do
    all_candidates = load_all_io_candidates()

    socket =
      socket
      |> assign(:picker_purpose, :import)
      |> assign(:show_io_picker, true)
      |> assign(:io_picker_all_candidates, all_candidates)
      |> assign(:io_picker_candidates, all_candidates)
      |> assign(:io_picker_selected, [])
      |> assign(:io_picker_selected_meta, %{})
      |> assign(:io_picker_query, "")

    {:noreply, socket}
  end

  @doc false
  # Opens the picker in "manual link" mode — attaches a traceability
  # reference without touching lines. Unlike "open_io_picker" (line import),
  # this works regardless of draft/posted status. `kind` is "internal_order"
  # (candidates: posted internal orders) or "order" (candidates: customer
  # orders/sub-orders).
  @impl true
  def handle_event("open_link_picker", %{"kind" => kind}, socket) do
    {purpose, all_candidates} =
      case kind do
        "internal_order" -> {:link_internal_order, load_all_io_candidates()}
        "order" -> {:link_order, InternalOrders.list_import_candidates()}
      end

    socket =
      socket
      |> assign(:picker_purpose, purpose)
      |> assign(:show_io_picker, true)
      |> assign(:io_picker_all_candidates, all_candidates)
      |> assign(:io_picker_candidates, all_candidates)
      |> assign(:io_picker_selected, [])
      |> assign(:io_picker_selected_meta, %{})
      |> assign(:io_picker_query, "")

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_io_picker", _params, socket) do
    {:noreply, assign(socket, :show_io_picker, false)}
  end

  @impl true
  def handle_event("source_picker_search", %{"query" => query}, socket) do
    all_candidates = socket.assigns.io_picker_all_candidates
    candidates = filter_io_candidates(all_candidates, query)

    socket =
      socket
      |> assign(:io_picker_candidates, candidates)
      |> assign(:io_picker_query, query)

    {:noreply, socket}
  end

  @impl true
  def handle_event("source_picker_toggle", %{"uuid" => uuid}, socket) do
    selected = socket.assigns.io_picker_selected
    meta = socket.assigns.io_picker_selected_meta

    {selected, meta} =
      if uuid in selected do
        {List.delete(selected, uuid), Map.delete(meta, uuid)}
      else
        candidate = Enum.find(socket.assigns.io_picker_candidates, &(&1.uuid == uuid))
        {selected ++ [uuid], Map.put(meta, uuid, candidate && Map.get(candidate, :kind))}
      end

    {:noreply,
     socket
     |> assign(:io_picker_selected, selected)
     |> assign(:io_picker_selected_meta, meta)}
  end

  @impl true
  def handle_event("source_picker_select_all", _params, socket) do
    candidates = socket.assigns.io_picker_candidates
    selected = socket.assigns.io_picker_selected

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
     |> assign(:io_picker_selected, selected)
     |> assign(:io_picker_selected_meta, meta)}
  end

  @impl true
  def handle_event(
        "source_picker_confirm",
        _params,
        %{assigns: %{picker_purpose: :import}} = socket
      ) do
    issue = socket.assigns.issue
    selected = socket.assigns.io_picker_selected
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid

    case GoodsIssues.import_from_internal_orders(issue, selected, user_uuid) do
      {:ok, updated_issue} ->
        sub_order_ref = DocRefs.sub_order_ref(sub_order_uuid_of(updated_issue))
        internal_order_ref = DocRefs.internal_order_ref(updated_issue.internal_order_uuid)

        socket =
          socket
          |> assign(:issue, updated_issue)
          |> assign(:lines, updated_issue.lines)
          |> assign(:refs_by_kind, refs_by_kind(updated_issue))
          |> assign(:sub_order_ref, sub_order_ref)
          |> assign(:internal_order_ref, internal_order_ref)
          |> assign(:show_io_picker, false)
          |> assign(:io_picker_selected, [])
          |> put_flash(:info, dgettext("default", "Lines imported from internal order(s)"))

        {:noreply, socket}

      {:error, :no_valid_orders} ->
        {:noreply,
         socket
         |> assign(:show_io_picker, false)
         |> put_flash(:error, dgettext("default", "No valid posted internal orders found"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to import lines"))}
    end
  end

  def handle_event("source_picker_confirm", _params, socket) do
    issue = socket.assigns.issue
    purpose = socket.assigns.picker_purpose
    selected = socket.assigns.io_picker_selected
    meta = socket.assigns.io_picker_selected_meta

    result =
      Enum.reduce_while(selected, {:ok, issue}, fn uuid, {:ok, current_issue} ->
        type = link_ref_type(purpose, meta, uuid)

        case GoodsIssues.add_source_ref(current_issue, type, uuid) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, updated_issue} ->
        socket =
          socket
          |> assign(:issue, updated_issue)
          |> assign(:refs_by_kind, refs_by_kind(updated_issue))
          |> assign(:show_io_picker, false)
          |> assign(:io_picker_selected, [])
          |> assign(:io_picker_selected_meta, %{})
          |> put_flash(:info, dgettext("default", "Link added"))

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:show_io_picker, false)
         |> put_flash(:error, dgettext("default", "Failed to add link"))}
    end
  end

  @impl true
  def handle_event("remove_source_ref", %{"type" => type, "uuid" => uuid}, socket) do
    issue = socket.assigns.issue

    case GoodsIssues.remove_source_ref(issue, type, uuid) do
      {:ok, updated_issue} ->
        socket =
          socket
          |> assign(:issue, updated_issue)
          |> assign(:refs_by_kind, refs_by_kind(updated_issue))

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to remove link"))}
    end
  end

  # `Map.get(meta, uuid, "order")` alone isn't enough insurance: the key can
  # be present but mapped to `nil` (e.g. an unresolved candidate) rather
  # than absent, and `Map.get/3`'s default only kicks in when the key is
  # missing — so `|| "order"` catches that case too.
  defp link_ref_type(:link_order, meta, uuid), do: Map.get(meta, uuid) || "order"
  defp link_ref_type(:link_internal_order, _meta, _uuid), do: "internal_order"

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
      case socket.assigns.issue do
        %{uuid: uuid} when not is_nil(uuid) ->
          Comments.count(:goods_issue, uuid)

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
      |> assign(:posted?, assigns.issue && assigns.issue.status == "posted")
      |> assign(:issue_uuid, assigns.issue && assigns.issue.uuid)

    assigns = assign_new(assigns, :sub_order_ref, fn -> nil end)
    assigns = assign_new(assigns, :internal_order_ref, fn -> nil end)
    assigns = assign_new(assigns, :refs_by_kind, fn -> %{} end)

    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      current_path={
        assigns[:url_path] || assigns[:current_path] ||
          Routes.path("/admin/warehouse/goods-issues")
      }
      current_locale={assigns[:current_locale]}
    >
    <div class="flex flex-col mx-auto max-w-none sm:px-4 py-2 sm:py-6 gap-4">
      <div class="flex flex-wrap items-center justify-end gap-2">
        <%!-- Draft: Save draft + Post --%>
        <%= if !@posted? and @active_tab in [:general, :lines] do %>
          <button type="button" phx-click="save_draft" class="btn btn-ghost btn-sm">
            {dgettext("default", "Save draft")}
          </button>
          <button type="button" phx-click="post" class="btn btn-primary btn-sm">
            <.icon name="hero-check" class="w-4 h-4" /> {dgettext("default", "Issue")}
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
      </div>

      <%!-- Tab navigation --%>
      <div class="tabs tabs-border">
        <.link
          patch={Routes.path("/admin/warehouse/goods-issues/#{@issue_uuid}")}
          class={["tab", @active_tab == :general && "tab-active"]}
        >
          {dgettext("default", "General")}
        </.link>
        <.link
          :if={@issue_uuid}
          patch={Routes.path("/admin/warehouse/goods-issues/#{@issue_uuid}/lines")}
          class={["tab", @active_tab == :lines && "tab-active"]}
        >
          {dgettext("default", "Lines")}
        </.link>
        <.link
          :if={@issue_uuid}
          patch={Routes.path("/admin/warehouse/goods-issues/#{@issue_uuid}/files")}
          class={["tab", @active_tab == :files && "tab-active"]}
        >
          {dgettext("default", "Files")}
        </.link>
        <.link
          :if={@issue_uuid}
          patch={Routes.path("/admin/warehouse/goods-issues/#{@issue_uuid}/comments")}
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
          <span>{dgettext("default", "This goods issue has been posted and stock has been updated.")}</span>
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
                  id="gi-note-input"
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

        <%= if @issue do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4">
              <dl class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-sm">
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Number")}</dt>
                  <dd class="mt-0.5 font-mono">#GI-{@issue.number}</dd>
                </div>
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Status")}</dt>
                  <dd class="mt-0.5">
                    <span class={[
                      "badge badge-sm",
                      @issue.status == "posted" && "badge-success",
                      @issue.status == "draft" && "badge-warning"
                    ]}>
                      {@issue.status}
                    </span>
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
                              selected={@issue.location_uuid == warehouse.uuid}
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
                <%= if @internal_order_ref do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Internal Order")}
                    </dt>
                    <dd class="mt-0.5">
                      <.link
                        navigate={@internal_order_ref.path}
                        class="link link-primary font-mono text-sm"
                      >
                        {@internal_order_ref.label}
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
                  title={dgettext("default", "Internal orders")}
                  refs={@refs_by_kind[:internal_order] || []}
                  link_kind="internal_order"
                />
                <%= if @issue.inserted_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Created")}
                    </dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@issue.inserted_at, "%Y-%m-%d %H:%M")}
                    </dd>
                  </div>
                <% end %>
                <%= if @issue.posted_at do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">{dgettext("default", "Posted at")}</dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@issue.posted_at, "%Y-%m-%d %H:%M")}
                    </dd>
                  </div>
                <% end %>
                <%= if @issue.note && @posted? do %>
                  <div>
                    <dt class="text-base-content/60 font-medium">
                      {dgettext("default", "Note")}
                    </dt>
                    <dd class="mt-0.5">{@issue.note}</dd>
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
                      id="gi-note-posted-input"
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
              <h2 class="card-title text-base">{dgettext("default", "Issue Lines")}</h2>
              <%= if !@posted? do %>
                <button type="button" phx-click="open_io_picker" class="btn btn-outline btn-sm">
                  <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
                  {dgettext("default", "Import from internal order")}
                </button>
              <% end %>
            </div>
            <%= if @posted? do %>
              <div class="alert alert-info mb-2">
                <.icon name="hero-information-circle" class="w-5 h-5" />
                <span>{dgettext("default", "Lines are read-only on a posted goods issue.")}</span>
              </div>
            <% end %>
            <.goods_issue_lines_table
              lines={@lines}
              posted?={@posted?}
              on_hand_map={@on_hand_map}
            />
          </div>
        </div>
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
                  {dgettext("default", "Files are not available for this goods issue yet.")}
                </div>
              <% true -> %>
                <.live_component
                  module={PhoenixKitWeb.Components.MediaBrowser}
                  id={"media-browser-gi-#{@issue_uuid}"}
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
                kind={:goods_issue}
                resource_uuid={@issue_uuid}
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

      <%!-- Source picker modal: import lines from internal orders, or attach a manual link --%>
      <WarehouseBrowser.source_picker
        id="io-picker-modal"
        show={@show_io_picker}
        title={picker_title(@picker_purpose)}
        on_close="close_io_picker"
        candidates={@io_picker_candidates}
        selected_uuids={@io_picker_selected}
        search_query={@io_picker_query}
      />
    </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
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

  defp picker_title(:import), do: dgettext("default", "Import from internal order")
  defp picker_title(:link_order), do: dgettext("default", "Attach customer order")
  defp picker_title(:link_internal_order), do: dgettext("default", "Attach internal order")

  # Groups a goods issue's resolved source_refs by tier for the grouped display.
  defp refs_by_kind(issue) do
    (issue.source_refs || [])
    |> DocRefs.refs_for()
    |> Enum.group_by(& &1.kind)
  end

  # ---------------------------------------------------------------------------
  # Function component: lines table
  # ---------------------------------------------------------------------------

  attr(:lines, :list, required: true)
  attr(:posted?, :boolean, required: true)
  attr(:on_hand_map, :map, required: true)

  defp goods_issue_lines_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>{dgettext("default", "Item")}</th>
            <th class="w-16 text-center">{dgettext("default", "Unit")}</th>
            <th class="w-28 text-right">{dgettext("default", "On hand")}</th>
            <th class="w-28 text-right">{dgettext("default", "Issue qty")}</th>
            <th class="w-28 text-right">{dgettext("default", "Prior stock")}</th>
          </tr>
        </thead>
        <tbody>
          <%= if @lines == [] do %>
            <tr>
              <td colspan="5" class="text-center text-base-content/50 py-4">
                {dgettext("default", "No lines yet")}
              </td>
            </tr>
          <% end %>
          <%= for {line, index} <- Enum.with_index(@lines) do %>
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
                {fmt_qty(Map.get(@on_hand_map, line["item_uuid"]))}
              </td>
              <td class="text-right">
                <%= if @posted? do %>
                  <span class="tabular-nums text-sm">{fmt_qty(line["issued_quantity"])}</span>
                <% else %>
                  <form
                    id={"gi-iss-form-#{index}"}
                    phx-change="set_issued_qty"
                    phx-submit="set_issued_qty"
                  >
                    <input type="hidden" name="index" value={index} />
                    <input
                      type="number"
                      id={"gi-iss-#{index}"}
                      name="issued_quantity"
                      min="0"
                      step="any"
                      value={fmt_qty(line["issued_quantity"])}
                      placeholder="0"
                      class="input input-sm w-24 text-right tabular-nums"
                      phx-debounce="blur"
                      phx-hook="InvEnterBlur"
                    />
                  </form>
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
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_all_io_candidates do
    InternalOrders.list_posted_internal_orders()
    |> Enum.map(fn order ->
      sub_uuid = sub_order_uuid_of(order)

      sub_label =
        if sub_uuid do
          case DocRefs.sub_order_ref(sub_uuid) do
            %{label: label} -> label
            nil -> nil
          end
        end

      %{
        uuid: order.uuid,
        label: "#IO-#{order.number}",
        label_prefix: order.status,
        note: sub_label
      }
    end)
  end

  defp filter_io_candidates(candidates, query)
       when is_binary(query) and byte_size(query) >= 2 do
    q = String.downcase(query)

    Enum.filter(candidates, fn c ->
      String.contains?(String.downcase(c.label), q) or
        (c.note && String.contains?(String.downcase(c.note), q))
    end)
  end

  defp filter_io_candidates(candidates, _query), do: candidates

  defp sub_order_uuid_of(%{source_refs: refs}) do
    Enum.find_value(refs || [], fn
      %{"type" => "sub_order", "uuid" => uuid} -> uuid
      _ -> nil
    end)
  end

  defp ensure_saved(%PhoenixKitWarehouse.GoodsIssue{status: "draft"} = issue, attrs) do
    GoodsIssues.update_draft(issue, attrs)
  end

  defp ensure_saved(%PhoenixKitWarehouse.GoodsIssue{} = issue, _attrs) do
    {:ok, issue}
  end

  defp clamp_non_negative(%Decimal{} = d) do
    zero = Decimal.new("0")
    if Decimal.compare(d, zero) == :lt, do: zero, else: d
  end

  defp fmt_qty(nil), do: "0"
  defp fmt_qty(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp fmt_qty(v), do: to_string(v)

  defp warehouse_options?(nil), do: false
  defp warehouse_options?([]), do: false
  defp warehouse_options?(_), do: true
end
