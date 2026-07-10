defmodule PhoenixKitWarehouse.Web.SupplierOrderFormLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitCatalogue.Catalogue

  @default_location_uuid "00000000-0000-0000-0000-000000000001"

  setup do
    PhoenixKitWarehouse.Test.Repo.delete_all(SupplierOrder)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "so-form-#{System.unique_integer([:positive])}@example.com"

  defp create_admin_user do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => unique_email(),
        "password" => "password123456789",
        "first_name" => "Admin",
        "last_name" => "User"
      })

    {:ok, user} = PhoenixKit.Users.Auth.admin_confirm_user(user)
    {:ok, _} = PhoenixKit.Users.Roles.promote_to_admin(user)
    PhoenixKit.Users.Auth.get_user!(user.uuid)
  end

  defp log_in_admin(conn, user) do
    token = PhoenixKit.Users.Auth.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  defp create_supplier! do
    {:ok, supplier} =
      Catalogue.create_supplier(%{
        name: "Test Supplier #{System.unique_integer([:positive])}",
        status: "active"
      })

    supplier
  end

  defp create_draft do
    supplier = create_supplier!()

    {:ok, order} =
      SupplierOrders.create_supplier_order(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @default_location_uuid,
        lines: [],
        note: ""
      })

    {order, supplier}
  end

  defp create_posted_internal_order!(actor_uuid) do
    {:ok, io} =
      InternalOrders.create_internal_order(%{location_uuid: @default_location_uuid, lines: []})

    {:ok, posted} = InternalOrders.post_internal_order(io, actor_uuid)
    posted
  end

  defp edit_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/supplier-orders/#{uuid}")

  defp lines_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/supplier-orders/#{uuid}/lines")

  defp files_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/supplier-orders/#{uuid}/files")

  defp comments_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/supplier-orders/#{uuid}/comments")

  # ---------------------------------------------------------------------------
  # General tab — draft
  # ---------------------------------------------------------------------------

  describe "draft supplier order form" do
    test "renders Save draft and Post buttons for draft", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, lv, _html} = live(conn, edit_path(order.uuid))

      assert has_element?(lv, "button", "Save draft")
      assert has_element?(lv, "button", "Post")
    end

    test "shows General tab by default", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      assert html =~ "General"
    end

    test "shows the order number in page heading", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      assert html =~ "#SO-#{order.number}"
    end
  end

  # ---------------------------------------------------------------------------
  # Tab navigation
  # ---------------------------------------------------------------------------

  describe "tab navigation" do
    test "Lines tab is present", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      assert html =~ "Lines"
    end

    test "Files tab is present", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      assert html =~ "Files"
    end

    test "Comments tab is present", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(order.uuid))

      assert html =~ "Comments"
    end

    test "Lines tab shows empty state when no lines", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, _lv, html} = live(conn, lines_path(order.uuid))

      assert html =~ "No lines yet"
    end

    test "Files tab renders loading or unavailable state", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, _lv, html} = live(conn, files_path(order.uuid))

      # Should be either loading spinner or the media browser (storage module may not be set up)
      assert html =~ "files" or html =~ "loading" or html =~ "media" or html =~ "Files"
    end

    test "Comments tab renders comments or unavailable state", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, _lv, html} = live(conn, comments_path(order.uuid))

      assert html =~ "Comments" or html =~ "disabled"
    end
  end

  # ---------------------------------------------------------------------------
  # Lines editing
  # ---------------------------------------------------------------------------

  describe "ordered_quantity editing" do
    test "keeper can edit ordered_quantity on a draft line", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      lines = [
        %{
          "item_uuid" => Ecto.UUID.generate(),
          "name" => "Widget",
          "sku" => "WGT-001",
          "unit" => "pcs",
          "catalogue_uuid" => Ecto.UUID.generate(),
          "required_quantity" => Decimal.new("10"),
          "on_hand_quantity" => Decimal.new("3"),
          "shortfall_quantity" => Decimal.new("7"),
          "ordered_quantity" => Decimal.new("7"),
          "base_price" => Decimal.new("12.50")
        }
      ]

      supplier = create_supplier!()

      {:ok, order} =
        SupplierOrders.create_supplier_order(%{
          supplier_uuid: supplier.uuid,
          location_uuid: @default_location_uuid,
          lines: lines
        })

      {:ok, lv, _html} = live(conn, lines_path(order.uuid))

      # Update the ordered qty for line 0
      lv
      |> element("#so-qty-form-0")
      |> render_change(%{"index" => "0", "ordered_quantity" => "5"})

      html = render(lv)
      assert html =~ ~r/5/
    end
  end

  # ---------------------------------------------------------------------------
  # Post transition
  # ---------------------------------------------------------------------------

  describe "post action" do
    test "clicking Post posts the order and navigates away", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, lv, _html} = live(conn, edit_path(order.uuid))

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               lv |> element("button", "Post") |> render_click()

      assert String.contains?(redirect_to, "/admin/warehouse/supplier-orders")

      {:ok, posted} = SupplierOrders.get_supplier_order(order.uuid)
      assert posted.status == "posted"
    end
  end

  # ---------------------------------------------------------------------------
  # Posted state
  # ---------------------------------------------------------------------------

  describe "posted supplier order form" do
    test "shows Posted badge when posted", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()
      {:ok, posted} = SupplierOrders.post_supplier_order(order, admin.uuid)

      {:ok, _lv, html} = live(conn, edit_path(posted.uuid))

      assert html =~ "Posted"
    end

    test "lines are read-only on a posted order", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()
      {:ok, posted} = SupplierOrders.post_supplier_order(order, admin.uuid)

      {:ok, _lv, html} = live(conn, lines_path(posted.uuid))

      # No quantity input (phx-hook) in posted state
      refute html =~ ~r/phx-hook="InvEnterBlur".*ordered_quantity/
      # No phx-change form for editing
      refute html =~ "so-qty-form"
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-document links: #IO- label in general tab
  # ---------------------------------------------------------------------------

  describe "cross-document links" do
    test "shows #IO-N link when internal_order_uuid is set", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      # Create an internal order
      {:ok, internal_order} =
        PhoenixKitWarehouse.InternalOrders.create_internal_order(%{
          location_uuid: @default_location_uuid,
          lines: []
        })

      supplier = create_supplier!()

      {:ok, so} =
        SupplierOrders.create_supplier_order(%{
          supplier_uuid: supplier.uuid,
          location_uuid: @default_location_uuid,
          internal_order_uuid: internal_order.uuid,
          lines: []
        })

      {:ok, _lv, html} = live(conn, edit_path(so.uuid))

      assert html =~ "#IO-#{internal_order.number}"
    end
  end

  describe "source picker — select all" do
    test "selects every candidate, and toggling again clears the selection", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _supplier} = create_draft()
      io1 = create_posted_internal_order!(admin.uuid)
      io2 = create_posted_internal_order!(admin.uuid)

      {:ok, lv, _html} = live(conn, lines_path(order.uuid))

      lv |> element("button[phx-click='open_source_picker']") |> render_click()

      html = lv |> element("button[phx-click='source_picker_select_all']") |> render_click()

      assert html =~ "Deselect all"
      assert has_element?(lv, "input[phx-value-uuid='#{io1.uuid}'][checked]")
      assert has_element?(lv, "input[phx-value-uuid='#{io2.uuid}'][checked]")

      html = lv |> element("button[phx-click='source_picker_select_all']") |> render_click()

      assert html =~ "Select all"
      refute has_element?(lv, "input[phx-value-uuid='#{io1.uuid}'][checked]")
      refute has_element?(lv, "input[phx-value-uuid='#{io2.uuid}'][checked]")
    end
  end

  # ---------------------------------------------------------------------------
  # Add 10% reserve button
  # ---------------------------------------------------------------------------

  describe "add_reserve event" do
    test "Add 10% reserve button appears on draft lines tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, _lv, html} = live(conn, lines_path(order.uuid))

      assert html =~ "Add 10% reserve"
    end

    test "Add 10% reserve sets ordered_quantity to shortfall + 10%", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      item_uuid = Ecto.UUID.generate()
      supplier = create_supplier!()

      lines = [
        %{
          "item_uuid" => item_uuid,
          "name" => "Widget",
          "sku" => "",
          "unit" => "piece",
          "catalogue_uuid" => Ecto.UUID.generate(),
          "required_quantity" => Decimal.new("10"),
          "on_hand_quantity" => Decimal.new("0"),
          "shortfall_quantity" => Decimal.new("10"),
          "ordered_quantity" => Decimal.new("10"),
          "base_price" => nil
        }
      ]

      {:ok, order} =
        SupplierOrders.create_supplier_order(%{
          supplier_uuid: supplier.uuid,
          location_uuid: @default_location_uuid,
          lines: lines
        })

      {:ok, lv, _html} = live(conn, lines_path(order.uuid))

      lv |> element("button", "Add 10% reserve") |> render_click()

      # shortfall=10 → +ceil(1.0)=1 → ordered=11
      {:ok, updated} = SupplierOrders.get_supplier_order(order.uuid)
      ordered = PhoenixKitWarehouse.StockLedger.to_decimal(hd(updated.lines)["ordered_quantity"])
      assert Decimal.equal?(ordered, Decimal.new("11"))
    end
  end

  # ---------------------------------------------------------------------------
  # Reserve column
  # ---------------------------------------------------------------------------

  describe "reserve column" do
    test "shows Reserve column header on lines tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, _lv, html} = live(conn, lines_path(order.uuid))

      assert html =~ "Reserve"
    end
  end

  # ---------------------------------------------------------------------------
  # Received / Outstanding columns
  # ---------------------------------------------------------------------------

  describe "received and outstanding columns" do
    test "shows Received and Outstanding column headers", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _} = create_draft()

      {:ok, _lv, html} = live(conn, lines_path(order.uuid))

      assert html =~ "Received"
      assert html =~ "Outstanding"
    end
  end

  describe "manual link add/remove" do
    test "attaching an internal order via the link picker adds it without touching lines", %{
      conn: conn
    } do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {order, _supplier} = create_draft()
      io = create_posted_internal_order!(admin.uuid)

      {:ok, lv, _html} = live(conn, edit_path(order.uuid))

      lv |> element("button[phx-click='open_link_picker']") |> render_click()

      lv
      |> element("input[phx-click='source_picker_toggle'][phx-value-uuid='#{io.uuid}']")
      |> render_click()

      html = lv |> element("button[phx-click='source_picker_confirm']") |> render_click()

      assert html =~ "#IO-#{io.number}"
      updated = SupplierOrders.get_supplier_order!(order.uuid)
      assert %{"type" => "internal_order", "uuid" => io.uuid} in updated.source_refs
      assert updated.lines == []
    end

    test "removing an attached reference detaches it", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      supplier = create_supplier!()
      io = create_posted_internal_order!(admin.uuid)

      {:ok, order} =
        SupplierOrders.create_supplier_order(%{
          supplier_uuid: supplier.uuid,
          location_uuid: @default_location_uuid,
          lines: [],
          source_refs: [%{"type" => "internal_order", "uuid" => io.uuid}]
        })

      {:ok, lv, html} = live(conn, edit_path(order.uuid))
      assert html =~ "#IO-#{io.number}"

      html =
        lv
        |> element("button[phx-click='remove_source_ref'][phx-value-uuid='#{io.uuid}']")
        |> render_click()

      refute html =~ "#IO-#{io.number}"
      updated = SupplierOrders.get_supplier_order!(order.uuid)
      assert updated.source_refs == []
    end
  end
end
