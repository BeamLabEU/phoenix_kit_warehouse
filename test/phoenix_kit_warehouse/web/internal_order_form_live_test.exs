defmodule PhoenixKitWarehouse.Web.InternalOrderFormLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Test.Fixtures
  alias PhoenixKitWarehouse.Test.Repo

  @default_location_uuid "00000000-0000-0000-0000-000000000001"

  setup do
    Repo.delete_all(InternalOrder)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "io-form-#{System.unique_integer([:positive])}@example.com"

  defp create_admin_user do
    {:ok, user} =
      Auth.register_user(%{
        "email" => unique_email(),
        "password" => "password123456789",
        "first_name" => "Admin",
        "last_name" => "User"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.promote_to_admin(user)
    Auth.get_user!(user.uuid)
  end

  defp log_in_admin(conn, user) do
    token = Auth.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  defp edit_path(uuid),
    do: Routes.path("/admin/warehouse/internal-orders/#{uuid}")

  defp items_path(uuid),
    do: Routes.path("/admin/warehouse/internal-orders/#{uuid}/items")

  defp files_path(uuid),
    do: Routes.path("/admin/warehouse/internal-orders/#{uuid}/files")

  defp comments_path(uuid),
    do: Routes.path("/admin/warehouse/internal-orders/#{uuid}/comments")

  defp create_draft do
    {:ok, order} =
      InternalOrders.create_internal_order(%{
        location_uuid: @default_location_uuid,
        lines: [],
        note: ""
      })

    order
  end

  defp create_catalogue_item! do
    {:ok, catalogue} =
      Catalogue.create_catalogue(%{name: "IO Form Test #{System.unique_integer([:positive])}"})

    {:ok, item} =
      Catalogue.create_item(%{
        name: "IO Test Item #{System.unique_integer([:positive])}",
        catalogue_uuid: catalogue.uuid,
        base_price: "10.00",
        status: "active"
      })

    item
  end

  # ---------------------------------------------------------------------------
  # :edit action — draft renders Save + Conduct
  # ---------------------------------------------------------------------------

  describe "draft internal order form" do
    test "renders Save draft and Conduct buttons for draft", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, lv, _html} = live(conn, edit_path(order.uuid))

      assert has_element?(lv, "button", "Save draft")
      assert has_element?(lv, "button", "Conduct")
    end

    test "shows General tab by default", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      assert html =~ "General"
    end

    test "shows the order number in page heading", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      assert html =~ "#IO-#{order.number}"
    end
  end

  # ---------------------------------------------------------------------------
  # Conduct transitions to posted
  # ---------------------------------------------------------------------------

  describe "conduct action" do
    test "clicking Conduct posts the order and navigates away", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, lv, _html} = live(conn, edit_path(order.uuid))

      # Conduct button triggers a redirect after saving + posting
      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               lv |> element("button", "Conduct") |> render_click()

      assert String.contains?(redirect_to, "/admin/warehouse/internal-orders")

      # Verify the order is now posted
      {:ok, posted} = InternalOrders.get_internal_order(order.uuid)
      assert posted.status == "posted"
    end
  end

  # ---------------------------------------------------------------------------
  # Posted order — no edit controls
  # ---------------------------------------------------------------------------

  describe "posted internal order form" do
    test "shows Conducted badge and no Conduct button when posted", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      {:ok, posted} = InternalOrders.post_internal_order(order, admin.uuid)

      {:ok, _lv, html} = live(conn, edit_path(posted.uuid))

      assert html =~ "Conducted"
      refute html =~ "phx-click=\"conduct\""
    end
  end

  # ---------------------------------------------------------------------------
  # Items tab
  # ---------------------------------------------------------------------------

  describe "items tab" do
    test "renders Items tab link", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      assert html =~ "Items"
    end

    test "items tab shows empty state when no lines", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, _lv, html} = live(conn, items_path(order.uuid))

      assert html =~ "No items yet"
    end
  end

  # ---------------------------------------------------------------------------
  # Files tab
  # ---------------------------------------------------------------------------

  describe "files tab" do
    test "Files tab link is present on the form", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      assert html =~ "Files"
    end

    test "Files tab route is reachable and renders loading or unavailable state", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, lv, _html} = live(conn, files_path(order.uuid))

      # The :files action mounted and landed on the Files tab (active), i.e. the
      # route + handle_params + tab body rendered without crashing.
      assert has_element?(lv, "a.tab-active", "Files")
    end

    test "Files tab is reachable on a posted order", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      {:ok, posted} = InternalOrders.post_internal_order(order, admin.uuid)

      {:ok, lv, _html} = live(conn, files_path(posted.uuid))

      assert has_element?(lv, "a.tab-active", "Files")
    end
  end

  # ---------------------------------------------------------------------------
  # Comments tab
  # ---------------------------------------------------------------------------

  describe "comments tab" do
    test "Comments tab link is present on the form", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      assert html =~ "Comments"
    end

    test "Comments tab route is reachable and renders comments or disabled state", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, lv, _html} = live(conn, comments_path(order.uuid))

      # The :comments action mounted and landed on the Comments tab (active).
      assert has_element?(lv, "a.tab-active", "Comments")
    end

    test "Comments tab is reachable on a posted order", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      {:ok, posted} = InternalOrders.post_internal_order(order, admin.uuid)

      {:ok, lv, _html} = live(conn, comments_path(posted.uuid))

      assert has_element?(lv, "a.tab-active", "Comments")
    end
  end

  describe "manual link add/remove" do
    test "attaching a customer order via the link picker adds it without touching lines", %{
      conn: conn
    } do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      customer_order = Fixtures.insert_order!()

      {:ok, lv, _html} = live(conn, edit_path(order.uuid))

      lv |> element("button[phx-click='open_link_picker']") |> render_click()

      lv
      |> element(
        "input[phx-click='source_picker_toggle'][phx-value-uuid='#{customer_order.uuid}']"
      )
      |> render_click()

      html = lv |> element("button[phx-click='source_picker_confirm']") |> render_click()

      assert html =~ "##{customer_order.data["order_number"]}"
      updated = InternalOrders.get_internal_order!(order.uuid)
      assert %{"type" => "order", "uuid" => customer_order.uuid} in updated.source_refs
      assert updated.lines == []
    end

    test "removing an attached reference detaches it", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      customer_order = Fixtures.insert_order!()

      {:ok, order} =
        InternalOrders.create_internal_order(%{
          location_uuid: @default_location_uuid,
          lines: [],
          source_refs: [%{"type" => "order", "uuid" => customer_order.uuid}]
        })

      {:ok, lv, html} = live(conn, edit_path(order.uuid))
      assert html =~ "##{customer_order.data["order_number"]}"

      html =
        lv
        |> element(
          "button[phx-click='remove_source_ref'][phx-value-uuid='#{customer_order.uuid}']"
        )
        |> render_click()

      refute html =~ "##{customer_order.data["order_number"]}"
      updated = InternalOrders.get_internal_order!(order.uuid)
      assert updated.source_refs == []
    end
  end

  describe "downstream related documents" do
    test "shows links to child supplier orders and goods issues", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, supplier_order} =
        SupplierOrders.create_supplier_order(%{
          internal_order_uuid: order.uuid,
          location_uuid: @default_location_uuid,
          lines: []
        })

      {:ok, goods_issue} =
        GoodsIssues.create_goods_issue(%{
          internal_order_uuid: order.uuid,
          location_uuid: @default_location_uuid,
          lines: []
        })

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      assert html =~ "Related documents"
      assert html =~ "#SO-#{supplier_order.number}"
      assert html =~ "#GI-#{goods_issue.number}"
    end

    test "does not show the Related documents block when there are no child documents", %{
      conn: conn
    } do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      refute html =~ "Related documents"
    end
  end

  describe "source picker — select all" do
    test "selects every candidate, and toggling again clears the selection", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      order1 = Fixtures.insert_order!()
      order2 = Fixtures.insert_order!()

      {:ok, lv, _html} = live(conn, items_path(order.uuid))

      lv |> element("button[phx-click='open_source_picker']") |> render_click()

      html = lv |> element("button[phx-click='source_picker_select_all']") |> render_click()

      assert html =~ "Deselect all"
      assert has_element?(lv, "input[phx-value-uuid='#{order1.uuid}'][checked]")
      assert has_element?(lv, "input[phx-value-uuid='#{order2.uuid}'][checked]")

      html = lv |> element("button[phx-click='source_picker_select_all']") |> render_click()

      assert html =~ "Select all"
      refute has_element?(lv, "input[phx-value-uuid='#{order1.uuid}'][checked]")
      refute has_element?(lv, "input[phx-value-uuid='#{order2.uuid}'][checked]")
    end
  end

  describe "\"Add item\" button" do
    test "opens ItemSelectorModal", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, lv, html} = live(conn, items_path(order.uuid))

      refute html =~ "internal-order-item-selector"

      html = lv |> element("button[phx-click='open_item_selector']") |> render_click()

      assert html =~ "internal-order-item-selector"
      assert :sys.get_state(lv.pid).socket.assigns.show_item_selector == true
    end
  end

  describe "handle_info({:items_selected, ...}) (ItemSelectorModal confirm)" do
    test "adds a line seeded with the picked quantity", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      item = create_catalogue_item!()

      {:ok, lv, _html} = live(conn, items_path(order.uuid))

      pick = %{uuid: item.uuid, qty: Decimal.new("4"), unit: item.unit, name: item.name}
      send(lv.pid, {:items_selected, %{id: "internal-order-item-selector", picks: [pick]}})

      state = :sys.get_state(lv.pid)
      assert state.socket.assigns.show_item_selector == false
      [line] = state.socket.assigns.lines
      assert line["item_uuid"] == item.uuid
      assert line["required_quantity"] == "4"
    end

    test "set_required_qty accepts a comma value unrounded", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      item = create_catalogue_item!()

      {:ok, lv, _html} = live(conn, items_path(order.uuid))

      pick = %{uuid: item.uuid, qty: Decimal.new("4"), unit: item.unit, name: item.name}
      send(lv.pid, {:items_selected, %{id: "internal-order-item-selector", picks: [pick]}})
      :sys.get_state(lv.pid)

      lv
      |> element("#io-qty-form-0")
      |> render_change(%{"index" => "0", "required_quantity" => "2,5"})

      [line] = :sys.get_state(lv.pid).socket.assigns.lines
      assert line["required_quantity"] == "2.5"
    end

    test "set_required_qty clamps a negative and zeroes garbage", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      item = create_catalogue_item!()

      {:ok, lv, _html} = live(conn, items_path(order.uuid))

      pick = %{uuid: item.uuid, qty: Decimal.new("4"), unit: item.unit, name: item.name}
      send(lv.pid, {:items_selected, %{id: "internal-order-item-selector", picks: [pick]}})
      :sys.get_state(lv.pid)

      form = element(lv, "#io-qty-form-0")

      render_change(form, %{"index" => "0", "required_quantity" => "-3"})
      [line] = :sys.get_state(lv.pid).socket.assigns.lines
      assert line["required_quantity"] == "0"

      render_change(form, %{"index" => "0", "required_quantity" => "abc"})
      [line] = :sys.get_state(lv.pid).socket.assigns.lines
      assert line["required_quantity"] == "0"
    end

    test "set_required_qty accepts a dot value unrounded", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      item = create_catalogue_item!()

      {:ok, lv, _html} = live(conn, items_path(order.uuid))

      pick = %{uuid: item.uuid, qty: Decimal.new("4"), unit: item.unit, name: item.name}
      send(lv.pid, {:items_selected, %{id: "internal-order-item-selector", picks: [pick]}})
      :sys.get_state(lv.pid)

      lv
      |> element("#io-qty-form-0")
      |> render_change(%{"index" => "0", "required_quantity" => "0.25"})

      [line] = :sys.get_state(lv.pid).socket.assigns.lines
      assert line["required_quantity"] == "0.25"
    end

    test "re-adding an already-present item does not duplicate it", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      item = create_catalogue_item!()

      {:ok, lv, _html} = live(conn, items_path(order.uuid))

      pick = %{uuid: item.uuid, qty: Decimal.new("2"), unit: item.unit, name: item.name}
      send(lv.pid, {:items_selected, %{id: "internal-order-item-selector", picks: [pick]}})
      send(lv.pid, {:items_selected, %{id: "internal-order-item-selector", picks: [pick]}})

      state = :sys.get_state(lv.pid)
      assert length(state.socket.assigns.lines) == 1
    end

    test "a missing catalogue item is skipped instead of crashing the LiveView", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, lv, _html} = live(conn, items_path(order.uuid))

      pick = %{
        uuid: Ecto.UUID.generate(),
        qty: Decimal.new("1"),
        unit: "pcs",
        name: "gone"
      }

      send(lv.pid, {:items_selected, %{id: "internal-order-item-selector", picks: [pick]}})

      assert :sys.get_state(lv.pid).socket.assigns.lines == []
    end

    test "does nothing once the order is posted", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      {:ok, posted} = InternalOrders.post_internal_order(order, admin.uuid)
      item = create_catalogue_item!()

      {:ok, lv, _html} = live(conn, items_path(posted.uuid))

      pick = %{uuid: item.uuid, qty: Decimal.new("2"), unit: item.unit, name: item.name}
      send(lv.pid, {:items_selected, %{id: "internal-order-item-selector", picks: [pick]}})

      state = :sys.get_state(lv.pid)
      assert state.socket.assigns.lines == []
    end
  end

  describe "handle_info({:item_selector_closed, ...})" do
    test "closes the modal", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, lv, _html} = live(conn, items_path(order.uuid))

      :sys.replace_state(lv.pid, fn s -> put_in(s.socket.assigns[:show_item_selector], true) end)

      send(lv.pid, {:item_selector_closed, %{id: "internal-order-item-selector"}})

      assert :sys.get_state(lv.pid).socket.assigns.show_item_selector == false
    end
  end
end
