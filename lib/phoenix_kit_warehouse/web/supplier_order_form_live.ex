defmodule PhoenixKitWarehouse.Web.SupplierOrderFormLive do
  @moduledoc """
  LiveView for creating and editing supplier orders.

  Handles:
  - `:new`      — creates an empty draft (no supplier, no lines) and
                  push_navigate to :edit. Immediate-draft pattern.
  - `:edit`     — loads an existing order; :general tab.
  - `:lines`    — ordered lines editor (ordered_quantity editable on draft).
  - `:files`    — MediaBrowser; storage folder resolved asynchronously.
  - `:comments` — supplier order comments thread.

  Uses the admin-chrome pattern: `use PhoenixKitWeb, :live_view` +
  `<.admin_page_header>`. No `<Layouts.app>`, no streams.
  All navigation paths wrapped in `PhoenixKit.Utils.Routes.path/1`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWarehouse.Gettext
  use PhoenixKitComments.Embed

  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.DocRefs
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.Comments
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.StorageFolders
  alias PhoenixKitWarehouse.Web.Components.{CommentsPanel, WarehouseBrowser}

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue

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
      |> assign(:order, nil)
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
      |> assign(:internal_order_ref, nil)
      |> assign(:sub_order_ref, nil)
      |> assign(:received_summary, %{})
      |> assign(:source_refs, [])
      |> assign(:suppliers, [])
      |> assign(:show_source_picker, false)
      |> assign(:picker_purpose, :import)
      |> assign(:source_picker_candidates, [])
      |> assign(:source_picker_selected, [])
      |> assign(:source_picker_query, "")
      |> assign(:page_title, dgettext("default", "Supplier Order"))
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
        socket = load_order_into_socket(socket, uuid)

        {:noreply,
         socket |> assign(:active_tab, :general) |> maybe_subscribe_and_refresh_comments()}

      :lines ->
        uuid = params["uuid"]
        socket = load_order_into_socket(socket, uuid)

        {:noreply,
         socket |> assign(:active_tab, :lines) |> maybe_subscribe_and_refresh_comments()}

      :files ->
        uuid = params["uuid"]
        socket = load_order_into_socket(socket, uuid)

        {:noreply,
         socket
         |> assign(:active_tab, :files)
         |> maybe_start_files_folder_resolution()
         |> maybe_subscribe_and_refresh_comments()}

      :comments ->
        uuid = params["uuid"]
        socket = load_order_into_socket(socket, uuid)

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

    attrs = %{
      lines: [],
      created_by_uuid: user_uuid
    }

    case SupplierOrders.create_supplier_order(attrs) do
      {:ok, order} ->
        {:noreply,
         push_navigate(socket,
           to: Routes.path("/admin/warehouse/supplier-orders/#{order.uuid}")
         )}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("default", "Failed to create draft supplier order"))
         |> push_navigate(to: Routes.path("/admin/warehouse/supplier-orders"))}
    end
  end

  defp load_order_into_socket(socket, uuid) do
    order = SupplierOrders.get_supplier_order!(uuid)
    same_order? = match?(%{uuid: ^uuid}, socket.assigns[:order])

    suppliers =
      if same_order?, do: socket.assigns.suppliers, else: SupplierOrders.list_suppliers()

    supplier_name = resolve_supplier_name(order.supplier_uuid)
    location_name = resolve_location_name(order.location_uuid)
    internal_order_ref = DocRefs.internal_order_ref(order.internal_order_uuid)

    sub_order_ref =
      if internal_order_ref do
        # Resolve sub-order via the internal order's sub_order_uuid
        internal_order =
          PhoenixKitWarehouse.InternalOrders.get_internal_order!(order.internal_order_uuid)

        DocRefs.sub_order_ref(sub_order_uuid_of(internal_order))
      end

    received_summary = SupplierOrders.received_summary(order)
    source_refs = DocRefs.refs_for(order.source_refs || [])

    socket =
      socket
      |> assign(:order, order)
      |> assign(:suppliers, suppliers)
      |> assign(:supplier_name, supplier_name)
      |> assign(:location_name, location_name)
      |> assign(:internal_order_ref, internal_order_ref)
      |> assign(:sub_order_ref, sub_order_ref)
      |> assign(:received_summary, received_summary)
      |> assign(:source_refs, source_refs)
      |> assign(
        :page_title,
        dgettext("default", "Supplier Order #%{number}", number: order.number)
      )

    if same_order?, do: socket, else: assign_edit_buffer(socket, order)
  end

  defp assign_edit_buffer(socket, order) do
    socket
    |> assign(:lines, order.lines)
    |> assign(:note, order.note || "")
  end

  defp maybe_subscribe_and_refresh_comments(socket) do
    order = socket.assigns.order

    if connected?(socket) and order do
      socket =
        if socket.assigns.comments_subscribed? do
          socket
        else
          Comments.subscribe(:supplier_order, [order.uuid])
          assign(socket, :comments_subscribed?, true)
        end

      count = Comments.count(:supplier_order, order.uuid)
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
        order = socket.assigns.order
        user_uuid = socket.assigns.current_user && socket.assigns.current_user.uuid

        Task.Supervisor.start_child(PhoenixKitWarehouse.TaskSupervisor, fn ->
          result = StorageFolders.ensure_for_supplier_order(order, user_uuid)
          send(lv_pid, {:files_folder_result, result})
        end)

        assign(socket, :files_folder_loading, true)
    end
  end

  # ---------------------------------------------------------------------------
  # Supplier selection
  # ---------------------------------------------------------------------------

  # MediaBrowser allows the `:media_files` upload on this parent LiveView
  # (see setup_uploads/1), so its `phx-change="validate"` channel fires here.
  # Absorb it to avoid a FunctionClauseError crash on file upload.
  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("set_supplier", %{"supplier_uuid" => supplier_uuid}, socket) do
    order = socket.assigns.order

    case order do
      %PhoenixKitWarehouse.SupplierOrder{status: "draft"} ->
        supplier_uuid_val = if supplier_uuid == "", do: nil, else: supplier_uuid

        attrs = %{
          note: socket.assigns.note,
          lines: socket.assigns.lines,
          supplier_uuid: supplier_uuid_val
        }

        case SupplierOrders.update_draft(order, attrs) do
          {:ok, updated_order} ->
            supplier_name = resolve_supplier_name(supplier_uuid_val)

            {:noreply,
             socket
             |> assign(:order, updated_order)
             |> assign(:supplier_name, supplier_name)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, dgettext("default", "Failed to set supplier"))}
        end

      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("default", "Cannot modify: document is not a draft"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Line quantity editing
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("set_ordered_qty", params, socket) do
    index = String.to_integer(params["index"])
    raw = params["ordered_quantity"] || "0"

    qty = StockLedger.to_decimal(raw) |> clamp_non_negative()

    lines =
      socket.assigns.lines
      |> List.update_at(index, fn line ->
        Map.put(line, "ordered_quantity", qty)
      end)

    {:noreply, assign(socket, :lines, lines)}
  end

  # ---------------------------------------------------------------------------
  # Add 10% reserve (draft only)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("add_reserve", _params, %{assigns: %{order: %{status: "draft"}}} = socket) do
    lines =
      Enum.map(socket.assigns.lines, fn line ->
        shortfall = StockLedger.to_decimal(line["shortfall_quantity"] || "0")
        reserve_add = Decimal.round(Decimal.mult(shortfall, Decimal.new("0.10")), 0, :ceiling)
        new_ordered = Decimal.add(shortfall, reserve_add)
        # Never below shortfall
        new_ordered = Decimal.max(shortfall, new_ordered)
        Map.put(line, "ordered_quantity", new_ordered)
      end)

    attrs = %{note: socket.assigns.note, lines: lines}
    order = socket.assigns.order

    case SupplierOrders.update_draft(order, attrs) do
      {:ok, updated_order} ->
        {:noreply,
         socket
         |> assign(:order, updated_order)
         |> assign(:lines, lines)
         |> put_flash(:info, dgettext("default", "10% reserve applied"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Failed to apply reserve"))}
    end
  end

  def handle_event("add_reserve", _params, socket) do
    {:noreply,
     put_flash(socket, :error, dgettext("default", "Cannot modify: document is not a draft"))}
  end

  # ---------------------------------------------------------------------------
  # Note editing
  # ---------------------------------------------------------------------------

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
      %PhoenixKitWarehouse.SupplierOrder{status: "draft"} = order ->
        case SupplierOrders.update_draft(order, attrs) do
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

    order = socket.assigns.order

    with {:ok, saved_order} <- ensure_saved(order, save_attrs),
         {:ok, _posted_order} <- SupplierOrders.post_supplier_order(saved_order, user_uuid) do
      {:noreply,
       socket
       |> put_flash(:info, dgettext("default", "Supplier order posted"))
       |> push_navigate(to: Routes.path("/admin/warehouse/supplier-orders"))}
    else
      {:error, :not_draft} ->
        {:noreply, put_flash(socket, :error, dgettext("default", "Document is already posted"))}

      {:error, changeset} when is_map(changeset) ->
        # Likely a changeset with supplier_uuid required error
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("default", "Cannot post: please set a supplier first")
         )}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, dgettext("default", "Failed to post supplier order"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Register receipt (creates a goods receipt from this posted supplier order)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event(
        "register_receipt",
        _params,
        %{assigns: %{order: %{status: "posted"}}} = socket
      ) do
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid
    order = socket.assigns.order

    case GoodsReceipts.create_from_supplier_order(order, user_uuid) do
      {:ok, receipt} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext("default", "Goods receipt #GR-%{number} created", number: receipt.number)
         )
         |> push_navigate(to: Routes.path("/admin/warehouse/goods-receipts/#{receipt.uuid}"))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, dgettext("default", "Failed to create goods receipt"))}
    end
  end

  def handle_event("register_receipt", _params, socket) do
    {:noreply, put_flash(socket, :error, dgettext("default", "Order is not posted"))}
  end

  # ---------------------------------------------------------------------------
  # Save correction (note-only admin)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_correction", _params, %{assigns: %{admin?: false}} = socket) do
    {:noreply, put_flash(socket, :error, dgettext("default", "Not authorized"))}
  end

  def handle_event("save_correction", _params, socket) do
    order = socket.assigns.order
    attrs = %{note: socket.assigns.note}

    case SupplierOrders.correct_supplier_order(order, attrs) do
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
  # Source picker — open/close/search/toggle/confirm
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("open_source_picker", _params, socket) do
    order = socket.assigns.order

    case order do
      %PhoenixKitWarehouse.SupplierOrder{status: "draft", supplier_uuid: nil} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("default", "Please set a supplier before importing lines")
         )}

      %PhoenixKitWarehouse.SupplierOrder{status: "draft"} ->
        {:noreply,
         socket
         |> assign(:picker_purpose, :import)
         |> assign(:show_source_picker, true)
         |> assign(:source_picker_candidates, build_io_candidates())
         |> assign(:source_picker_selected, [])
         |> assign(:source_picker_query, "")}

      _ ->
        {:noreply,
         put_flash(socket, :error, dgettext("default", "Cannot modify: document is not a draft"))}
    end
  end

  @doc false
  # Opens the picker in "manual link" mode — attaches a traceability
  # reference without touching lines. Unlike "open_source_picker" (line
  # import), this works regardless of supplier/draft status.
  @impl true
  def handle_event("open_link_picker", _params, socket) do
    socket =
      socket
      |> assign(:picker_purpose, :link)
      |> assign(:show_source_picker, true)
      |> assign(:source_picker_candidates, build_io_candidates())
      |> assign(:source_picker_selected, [])
      |> assign(:source_picker_query, "")

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_source_picker", _params, socket) do
    {:noreply, assign(socket, :show_source_picker, false)}
  end

  @impl true
  def handle_event("source_picker_search", %{"query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:source_picker_candidates, build_io_candidates(query))
     |> assign(:source_picker_query, query)}
  end

  @impl true
  def handle_event("source_picker_toggle", %{"uuid" => uuid}, socket) do
    selected = socket.assigns.source_picker_selected

    updated =
      if uuid in selected do
        List.delete(selected, uuid)
      else
        selected ++ [uuid]
      end

    {:noreply, assign(socket, :source_picker_selected, updated)}
  end

  @impl true
  def handle_event("source_picker_select_all", _params, socket) do
    candidates = socket.assigns.source_picker_candidates
    selected = socket.assigns.source_picker_selected

    all_selected? = candidates != [] && Enum.all?(candidates, &(&1.uuid in selected))

    updated =
      if all_selected? do
        []
      else
        Enum.uniq(selected ++ Enum.map(candidates, & &1.uuid))
      end

    {:noreply, assign(socket, :source_picker_selected, updated)}
  end

  @impl true
  def handle_event(
        "source_picker_confirm",
        _params,
        %{assigns: %{picker_purpose: :link}} = socket
      ) do
    order = socket.assigns.order
    selected_uuids = socket.assigns.source_picker_selected

    result =
      Enum.reduce_while(selected_uuids, {:ok, order}, fn uuid, {:ok, current_order} ->
        case SupplierOrders.add_source_ref(current_order, "internal_order", uuid) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, updated_order} ->
        socket =
          socket
          |> assign(:order, updated_order)
          |> assign(:source_refs, DocRefs.refs_for(updated_order.source_refs || []))
          |> assign(:show_source_picker, false)
          |> assign(:source_picker_selected, [])
          |> put_flash(:info, dgettext("default", "Link added"))

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:show_source_picker, false)
         |> put_flash(:error, dgettext("default", "Failed to add link"))}
    end
  end

  def handle_event("source_picker_confirm", _params, socket) do
    order = socket.assigns.order
    selected_uuids = socket.assigns.source_picker_selected
    current_user = socket.assigns.current_user
    user_uuid = current_user && current_user.uuid

    case order do
      %PhoenixKitWarehouse.SupplierOrder{supplier_uuid: nil} ->
        {:noreply,
         socket
         |> assign(:show_source_picker, false)
         |> put_flash(
           :error,
           dgettext("default", "Please set a supplier before importing lines")
         )}

      %PhoenixKitWarehouse.SupplierOrder{status: "draft"} ->
        case SupplierOrders.import_from_internal_orders(order, selected_uuids, user_uuid) do
          {:ok, updated_order} ->
            source_refs = DocRefs.refs_for(updated_order.source_refs || [])

            {:noreply,
             socket
             |> assign(:order, updated_order)
             |> assign(:lines, updated_order.lines)
             |> assign(:source_refs, source_refs)
             |> assign(:show_source_picker, false)
             |> assign(:source_picker_selected, [])
             |> put_flash(:info, dgettext("default", "Lines imported from internal order(s)"))}

          {:error, :no_supplier} ->
            {:noreply,
             socket
             |> assign(:show_source_picker, false)
             |> put_flash(
               :error,
               dgettext("default", "Please set a supplier before importing lines")
             )}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:show_source_picker, false)
             |> put_flash(:error, dgettext("default", "Failed to import lines"))}
        end

      _ ->
        {:noreply,
         socket
         |> assign(:show_source_picker, false)
         |> put_flash(:error, dgettext("default", "Cannot modify: document is not a draft"))}
    end
  end

  @impl true
  def handle_event("remove_source_ref", %{"type" => type, "uuid" => uuid}, socket) do
    order = socket.assigns.order

    case SupplierOrders.remove_source_ref(order, type, uuid) do
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
          Comments.count(:supplier_order, uuid)

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
      |> assign(:posted?, assigns.order && assigns.order.status == "posted")
      |> assign(:order_uuid, assigns.order && assigns.order.uuid)

    assigns = assign_new(assigns, :internal_order_ref, fn -> nil end)
    assigns = assign_new(assigns, :sub_order_ref, fn -> nil end)
    assigns = assign_new(assigns, :received_summary, fn -> %{} end)
    assigns = assign_new(assigns, :source_refs, fn -> [] end)

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
              <.icon name="hero-check" class="w-4 h-4" /> {dgettext("default", "Post")}
            </button>
          <% end %>
          <%!-- Posted + admin: correction --%>
          <%= if @posted? and @admin? and @active_tab == :general do %>
            <button type="button" phx-click="save_correction" class="btn btn-ghost btn-sm">
              {dgettext("default", "Save correction")}
            </button>
          <% end %>
          <%!-- Posted: register receipt --%>
          <%= if @posted? do %>
            <button type="button" phx-click="register_receipt" class="btn btn-secondary btn-sm">
              <.icon name="hero-inbox-arrow-down" class="w-4 h-4" /> {dgettext(
                "default",
                "Register receipt"
              )}
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
          patch={Routes.path("/admin/warehouse/supplier-orders/#{@order_uuid}")}
          class={["tab", @active_tab == :general && "tab-active"]}
        >
          {dgettext("default", "General")}
        </.link>
        <.link
          :if={@order_uuid}
          patch={Routes.path("/admin/warehouse/supplier-orders/#{@order_uuid}/lines")}
          class={["tab", @active_tab == :lines && "tab-active"]}
        >
          {dgettext("default", "Lines")}
        </.link>
        <.link
          :if={@order_uuid}
          patch={Routes.path("/admin/warehouse/supplier-orders/#{@order_uuid}/files")}
          class={["tab", @active_tab == :files && "tab-active"]}
        >
          {dgettext("default", "Files")}
        </.link>
        <.link
          :if={@order_uuid}
          patch={Routes.path("/admin/warehouse/supplier-orders/#{@order_uuid}/comments")}
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
          <span>{dgettext("default", "This supplier order has been posted and is now read-only.")}</span>
        </div>
      <% end %>

      <%!-- Tab: General --%>
      <%= if @active_tab == :general do %>
        <%!-- Note field (draft only) --%>
        <%= if !@posted? do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4">
              <form phx-change="set_note" phx-submit="set_note">
                <input
                  type="text"
                  id="so-note-input"
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

        <%!-- Supplier select (draft only) --%>
        <%= if !@posted? and @order do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4">
              <label class="text-base-content/60 font-medium text-sm block mb-1">
                {dgettext("default", "Supplier")}
              </label>
              <form phx-change="set_supplier" phx-submit="set_supplier">
                <select
                  name="supplier_uuid"
                  class="select select-sm w-full max-w-sm"
                  phx-debounce="0"
                >
                  <option value="">{dgettext("default", "— select supplier —")}</option>
                  <%= for supplier <- @suppliers do %>
                    <option
                      value={supplier.uuid}
                      selected={@order.supplier_uuid == supplier.uuid}
                    >
                      {supplier.name}
                    </option>
                  <% end %>
                </select>
              </form>
              <%= if is_nil(@order.supplier_uuid) do %>
                <p class="text-xs text-warning mt-1">
                  {dgettext("default", "A supplier is required before posting.")}
                </p>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @order do %>
          <div class="card bg-base-100 shadow-sm">
            <div class="card-body p-4">
              <dl class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-sm">
                <div>
                  <dt class="text-base-content/60 font-medium">{dgettext("default", "Number")}</dt>
                  <dd class="mt-0.5 font-mono">#SO-{@order.number}</dd>
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
                    <%= if @location_name do %>
                      {@location_name}
                    <% else %>
                      <span class="text-base-content/40">{dgettext("default", "— not set —")}</span>
                    <% end %>
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
                    <dt class="text-base-content/60 font-medium">{dgettext("default", "Posted at")}</dt>
                    <dd class="mt-0.5">
                      {Calendar.strftime(@order.posted_at, "%Y-%m-%d %H:%M")}
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
              <%!-- Source refs links --%>
              <div class="divider my-1"></div>
              <div class="text-sm">
                <p class="text-base-content/60 font-medium mb-2 flex items-center gap-1">
                  {dgettext("default", "Source documents")}
                  <button
                    type="button"
                    phx-click="open_link_picker"
                    class="btn btn-2xs btn-ghost btn-circle"
                    title={dgettext("default", "Attach")}
                  >
                    <.icon name="hero-plus" class="w-3 h-3" />
                  </button>
                </p>
                <div class="flex flex-wrap gap-2">
                  <span :if={@source_refs == []} class="text-base-content/30 text-sm">—</span>
                  <%= for ref <- @source_refs do %>
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
                </div>
              </div>
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
                      id="so-note-posted-input"
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
              <h2 class="card-title text-base">{dgettext("default", "Order Lines")}</h2>
              <div class="flex items-center gap-2">
                <%= if !@posted? do %>
                  <button
                    type="button"
                    phx-click="open_source_picker"
                    class="btn btn-outline btn-sm"
                  >
                    <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
                    {dgettext("default", "Import from internal order")}
                  </button>
                  <button
                    type="button"
                    phx-click="add_reserve"
                    class="btn btn-outline btn-sm"
                  >
                    {dgettext("default", "Add 10% reserve")}
                  </button>
                <% end %>
              </div>
            </div>
            <.supplier_order_lines_table
              lines={@lines}
              posted?={@posted?}
              received_summary={@received_summary}
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
                  {dgettext("default", "Files are not available for this supplier order yet.")}
                </div>
              <% true -> %>
                <.live_component
                  module={PhoenixKitWeb.Components.MediaBrowser}
                  id={"media-browser-so-#{@order_uuid}"}
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
                kind={:supplier_order}
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

      <%!-- Source picker modal: import lines from internal orders, or attach a manual link --%>
      <WarehouseBrowser.source_picker
        id="so-source-picker"
        show={@show_source_picker}
        title={picker_title(@picker_purpose)}
        on_close="close_source_picker"
        candidates={@source_picker_candidates}
        selected_uuids={@source_picker_selected}
        search_query={@source_picker_query}
      />
    </div>
    """
  end

  defp picker_title(:import), do: dgettext("default", "Import from internal order")
  defp picker_title(:link), do: dgettext("default", "Attach internal order")

  # ---------------------------------------------------------------------------
  # Function component: lines table
  # ---------------------------------------------------------------------------

  attr(:lines, :list, required: true)
  attr(:posted?, :boolean, required: true)
  attr(:received_summary, :map, default: %{})

  defp supplier_order_lines_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>{dgettext("default", "Item")}</th>
            <th class="w-16 text-center">{dgettext("default", "Unit")}</th>
            <th class="w-24 text-right">{dgettext("default", "Required")}</th>
            <th class="w-24 text-right">{dgettext("default", "On Hand")}</th>
            <th class="w-24 text-right">{dgettext("default", "Shortfall")}</th>
            <th class="w-28 text-right">{dgettext("default", "Order qty")}</th>
            <th class="w-20 text-right">{dgettext("default", "Reserve")}</th>
            <th class="w-24 text-right">{dgettext("default", "Received")}</th>
            <th class="w-28 text-right">{dgettext("default", "Outstanding")}</th>
            <th class="w-28 text-right">{dgettext("default", "Catalogue base price")}</th>
          </tr>
        </thead>
        <tbody>
          <%= if @lines == [] do %>
            <tr>
              <td colspan="10" class="text-center text-base-content/50 py-4">
                {dgettext("default", "No lines yet")}
              </td>
            </tr>
          <% end %>
          <%= for {line, index} <- Enum.with_index(@lines) do %>
            <% ordered = StockLedger.to_decimal(line["ordered_quantity"] || "0") %>
            <% shortfall = StockLedger.to_decimal(line["shortfall_quantity"] || "0") %>
            <% reserve = Decimal.sub(ordered, shortfall) %>
            <% received = Map.get(@received_summary, line["item_uuid"]) || Decimal.new("0") %>
            <% outstanding = Decimal.max(Decimal.new("0"), Decimal.sub(ordered, received)) %>
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
              <td class="text-right tabular-nums text-sm">
                {fmt_qty(line["required_quantity"])}
              </td>
              <td class="text-right tabular-nums text-sm">
                {fmt_qty(line["on_hand_quantity"])}
              </td>
              <td class="text-right tabular-nums text-sm">
                {fmt_qty(line["shortfall_quantity"])}
              </td>
              <td class="text-right">
                <%= if @posted? do %>
                  <span class="tabular-nums text-sm">{fmt_qty(line["ordered_quantity"])}</span>
                <% else %>
                  <form
                    id={"so-qty-form-#{index}"}
                    phx-change="set_ordered_qty"
                    phx-submit="set_ordered_qty"
                  >
                    <input type="hidden" name="index" value={index} />
                    <input
                      type="number"
                      id={"so-qty-#{index}"}
                      name="ordered_quantity"
                      min="0"
                      step="any"
                      value={fmt_qty(line["ordered_quantity"])}
                      placeholder="0"
                      class="input input-sm w-24 text-right tabular-nums"
                      phx-debounce="blur"
                      phx-hook="InvEnterBlur"
                    />
                  </form>
                <% end %>
              </td>
              <td class="text-right tabular-nums text-sm text-base-content/60">
                <%= if Decimal.compare(reserve, Decimal.new("0")) == :gt do %>
                  +{Decimal.to_string(reserve, :normal)}
                <% else %>
                  —
                <% end %>
              </td>
              <td class="text-right tabular-nums text-sm">
                {Decimal.to_string(received, :normal)}
              </td>
              <td class="text-right tabular-nums text-sm">
                {Decimal.to_string(outstanding, :normal)}
              </td>
              <td class="text-right tabular-nums text-sm text-base-content/60">
                {fmt_price(line["base_price"])}
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

  defp ensure_saved(%PhoenixKitWarehouse.SupplierOrder{status: "draft"} = order, attrs) do
    SupplierOrders.update_draft(order, attrs)
  end

  defp ensure_saved(%PhoenixKitWarehouse.SupplierOrder{} = order, _attrs) do
    {:ok, order}
  end

  defp clamp_non_negative(%Decimal{} = d) do
    zero = Decimal.new("0")
    if Decimal.compare(d, zero) == :lt, do: zero, else: d
  end

  defp fmt_qty(nil), do: "—"
  defp fmt_qty(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp fmt_qty(v), do: to_string(v)

  defp fmt_price(nil), do: "—"
  defp fmt_price(%Decimal{} = d), do: Decimal.to_string(Decimal.round(d, 2), :normal)
  defp fmt_price(v), do: to_string(v)

  # Builds source picker candidates from posted internal orders.
  # Optionally filters by query string (case-insensitive match on number).
  defp build_io_candidates(query \\ "") do
    SupplierOrders.list_posted_internal_orders()
    |> then(fn orders ->
      if query != "" do
        q = String.downcase(query)

        Enum.filter(orders, fn io ->
          String.contains?(String.downcase("#IO-#{io.number}"), q) or
            String.contains?(String.downcase(io.note || ""), q)
        end)
      else
        orders
      end
    end)
    |> Enum.map(fn io ->
      %{
        uuid: io.uuid,
        label: "#IO-#{io.number}",
        label_prefix: dgettext("default", "posted"),
        note: io.note
      }
    end)
  end

  defp sub_order_uuid_of(%{source_refs: refs}) do
    Enum.find_value(refs || [], fn
      %{"type" => "sub_order", "uuid" => uuid} -> uuid
      _ -> nil
    end)
  end
end
