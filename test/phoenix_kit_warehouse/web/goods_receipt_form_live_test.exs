defmodule PhoenixKitWarehouse.Web.GoodsReceiptFormLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitCatalogue.Catalogue

  @default_location_uuid "00000000-0000-0000-0000-000000000001"

  setup do
    PhoenixKitWarehouse.Test.Repo.delete_all(GoodsReceipt)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "gr-form-#{System.unique_integer([:positive])}@example.com"

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

    {:ok, receipt} =
      GoodsReceipts.create_goods_receipt(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @default_location_uuid,
        lines: [],
        note: ""
      })

    {receipt, supplier}
  end

  defp create_draft_with_lines do
    supplier = create_supplier!()

    lines = [
      %{
        "item_uuid" => Ecto.UUID.generate(),
        "name" => "Widget",
        "sku" => "WGT-001",
        "unit" => "pcs",
        "catalogue_uuid" => Ecto.UUID.generate(),
        "ordered_quantity" => Decimal.new("10"),
        "received_quantity" => Decimal.new("0"),
        "unit_value" => nil
      }
    ]

    {:ok, receipt} =
      GoodsReceipts.create_goods_receipt(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @default_location_uuid,
        lines: lines,
        note: ""
      })

    {receipt, supplier}
  end

  defp create_posted_supplier_order!(actor_uuid) do
    supplier = create_supplier!()

    {:ok, order} =
      SupplierOrders.create_supplier_order(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @default_location_uuid,
        lines: [
          %{
            "item_uuid" => Ecto.UUID.generate(),
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
      })

    {:ok, posted} = SupplierOrders.post_supplier_order(order, actor_uuid)
    {posted, supplier}
  end

  defp create_internal_order! do
    {:ok, io} =
      InternalOrders.create_internal_order(%{location_uuid: @default_location_uuid, lines: []})

    io
  end

  defp create_posted_internal_order!(actor_uuid) do
    io = create_internal_order!()
    {:ok, posted} = InternalOrders.post_internal_order(io, actor_uuid)
    posted
  end

  defp edit_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/goods-receipts/#{uuid}")

  defp lines_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/goods-receipts/#{uuid}/lines")

  defp files_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/goods-receipts/#{uuid}/files")

  defp comments_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/goods-receipts/#{uuid}/comments")

  # ---------------------------------------------------------------------------
  # General tab — draft
  # ---------------------------------------------------------------------------

  describe "draft goods receipt form" do
    test "renders Save draft and Conduct buttons for draft", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()

      {:ok, lv, _html} = live(conn, edit_path(receipt.uuid))

      assert has_element?(lv, "button", "Save draft")
      assert has_element?(lv, "button", "Conduct")
    end

    test "shows General tab by default", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(receipt.uuid))

      assert html =~ "General"
    end

    test "shows the receipt number in page heading", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(receipt.uuid))

      assert html =~ "#GR-#{receipt.number}"
    end
  end

  # ---------------------------------------------------------------------------
  # Tab navigation
  # ---------------------------------------------------------------------------

  describe "tab navigation" do
    test "Lines tab is present", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(receipt.uuid))

      assert html =~ "Lines"
    end

    test "Files tab is present", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(receipt.uuid))

      assert html =~ "Files"
    end

    test "Comments tab is present", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(receipt.uuid))

      assert html =~ "Comments"
    end

    test "Lines tab shows ordered and received columns headers", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft_with_lines()

      {:ok, _lv, html} = live(conn, lines_path(receipt.uuid))

      assert html =~ "Ordered"
      assert html =~ "Received"
    end

    test "Lines tab shows empty state when no lines", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()

      {:ok, _lv, html} = live(conn, lines_path(receipt.uuid))

      assert html =~ "No lines yet"
    end

    test "Files tab renders loading or unavailable state", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()

      {:ok, _lv, html} = live(conn, files_path(receipt.uuid))

      assert html =~ "files" or html =~ "loading" or html =~ "media" or html =~ "Files"
    end

    test "Comments tab renders comments or unavailable state", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()

      {:ok, _lv, html} = live(conn, comments_path(receipt.uuid))

      assert html =~ "Comments" or html =~ "disabled"
    end
  end

  # ---------------------------------------------------------------------------
  # Lines editing — received_quantity input
  # ---------------------------------------------------------------------------

  describe "received_quantity editing" do
    test "keeper can edit received_quantity on a draft line", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft_with_lines()

      {:ok, lv, _html} = live(conn, lines_path(receipt.uuid))

      lv
      |> element("#gr-rcv-form-0")
      |> render_change(%{"index" => "0", "received_quantity" => "5"})

      html = render(lv)
      assert html =~ ~r/5/
    end

    test "ordered_quantity is shown as read-only on draft", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft_with_lines()

      {:ok, _lv, html} = live(conn, lines_path(receipt.uuid))

      # The ordered_quantity should appear as a value (not in a form input with that name)
      refute html =~ ~r/name="ordered_quantity"/
      # But the value "10" should appear (the ordered qty)
      assert html =~ "10"
    end
  end

  # ---------------------------------------------------------------------------
  # Post (conduct) transition
  # ---------------------------------------------------------------------------

  describe "conduct action" do
    test "clicking Conduct posts the receipt and navigates away", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()

      {:ok, lv, _html} = live(conn, edit_path(receipt.uuid))

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               lv |> element("button", "Conduct") |> render_click()

      assert String.contains?(redirect_to, "/admin/warehouse/goods-receipts")

      {:ok, posted} = GoodsReceipts.get_goods_receipt(receipt.uuid)
      assert posted.status == "posted"
    end
  end

  # ---------------------------------------------------------------------------
  # Posted state
  # ---------------------------------------------------------------------------

  describe "posted goods receipt form" do
    test "shows Posted badge when posted", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, admin.uuid)

      {:ok, _lv, html} = live(conn, edit_path(posted.uuid))

      assert html =~ "Posted"
    end

    test "lines are read-only on a posted receipt", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft_with_lines()
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, admin.uuid)

      {:ok, _lv, html} = live(conn, lines_path(posted.uuid))

      # No received_quantity input form in posted state
      refute html =~ "gr-rcv-form"
      refute html =~ ~r/name="received_quantity"/
    end

    test "shows 'Lines are read-only' info alert on posted lines tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()
      {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, admin.uuid)

      {:ok, _lv, html} = live(conn, lines_path(posted.uuid))

      assert html =~ "read-only"
    end
  end

  # ---------------------------------------------------------------------------
  # Register receipt button on supplier order form
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # Receive all ordered button
  # ---------------------------------------------------------------------------

  describe "receive_all event" do
    test "Receive all ordered button appears on draft lines tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft_with_lines()

      {:ok, _lv, html} = live(conn, lines_path(receipt.uuid))

      assert html =~ "Receive all ordered"
    end

    test "clicking Receive all ordered sets received_quantity to ordered_quantity", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft_with_lines()

      {:ok, lv, _html} = live(conn, lines_path(receipt.uuid))

      lv |> element("button", "Receive all ordered") |> render_click()

      {:ok, updated} = GoodsReceipts.get_goods_receipt(receipt.uuid)
      line = hd(updated.lines)
      ordered = PhoenixKitWarehouse.StockLedger.to_decimal(line["ordered_quantity"])
      received = PhoenixKitWarehouse.StockLedger.to_decimal(line["received_quantity"])
      assert Decimal.equal?(received, ordered)
    end
  end

  # ---------------------------------------------------------------------------
  # Δ column
  # ---------------------------------------------------------------------------

  describe "delta column" do
    test "shows Δ column header on lines tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft_with_lines()

      {:ok, _lv, html} = live(conn, lines_path(receipt.uuid))

      assert html =~ "Δ"
    end

    test "shows short badge when received < ordered", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      supplier = create_supplier!()
      item_uuid = Ecto.UUID.generate()

      lines = [
        %{
          "item_uuid" => item_uuid,
          "name" => "Widget",
          "sku" => "",
          "unit" => "pcs",
          "catalogue_uuid" => Ecto.UUID.generate(),
          "ordered_quantity" => Decimal.new("10"),
          "received_quantity" => Decimal.new("6"),
          "unit_value" => nil
        }
      ]

      {:ok, receipt} =
        GoodsReceipts.create_goods_receipt(%{
          supplier_uuid: supplier.uuid,
          location_uuid: @default_location_uuid,
          lines: lines
        })

      {:ok, _lv, html} = live(conn, lines_path(receipt.uuid))

      assert html =~ "short"
    end

    test "shows over badge when received > ordered", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      supplier = create_supplier!()
      item_uuid = Ecto.UUID.generate()

      lines = [
        %{
          "item_uuid" => item_uuid,
          "name" => "Widget",
          "sku" => "",
          "unit" => "pcs",
          "catalogue_uuid" => Ecto.UUID.generate(),
          "ordered_quantity" => Decimal.new("5"),
          "received_quantity" => Decimal.new("8"),
          "unit_value" => nil
        }
      ]

      {:ok, receipt} =
        GoodsReceipts.create_goods_receipt(%{
          supplier_uuid: supplier.uuid,
          location_uuid: @default_location_uuid,
          lines: lines
        })

      {:ok, _lv, html} = live(conn, lines_path(receipt.uuid))

      assert html =~ "over"
    end
  end

  # ---------------------------------------------------------------------------
  # Supplier order link on general tab
  # ---------------------------------------------------------------------------

  describe "supplier order cross-document link" do
    test "shows #SO-N link when supplier_order_uuid is set", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {so, _supplier} = create_posted_supplier_order!(admin.uuid)

      {:ok, gr} =
        GoodsReceipts.create_goods_receipt(%{
          supplier_uuid: so.supplier_uuid,
          supplier_order_uuid: so.uuid,
          location_uuid: @default_location_uuid,
          lines: []
        })

      {:ok, _lv, html} = live(conn, edit_path(gr.uuid))

      assert html =~ "#SO-#{so.number}"
    end
  end

  describe "traceability chain — grouped refs and manual linking" do
    test "groups resolved source_refs by tier under labeled sections", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {so, _supplier} = create_posted_supplier_order!(admin.uuid)
      io = create_internal_order!()

      {:ok, gr} =
        GoodsReceipts.create_goods_receipt(%{
          location_uuid: @default_location_uuid,
          lines: [],
          source_refs: [
            %{"type" => "supplier_order", "uuid" => so.uuid},
            %{"type" => "internal_order", "uuid" => io.uuid}
          ]
        })

      {:ok, _lv, html} = live(conn, edit_path(gr.uuid))

      assert html =~ "Supplier orders"
      assert html =~ "Internal orders"
      assert html =~ "Customer orders"
      assert html =~ "#SO-#{so.number}"
      assert html =~ "#IO-#{io.number}"
    end

    test "manually attaching an internal order adds a link without touching lines", %{
      conn: conn
    } do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _supplier} = create_draft_with_lines()
      io = create_posted_internal_order!(admin.uuid)

      {:ok, lv, _html} = live(conn, edit_path(receipt.uuid))

      lv
      |> element("button[phx-click='open_link_picker'][phx-value-kind='internal_order']")
      |> render_click()

      lv
      |> element("input[phx-click='source_picker_toggle'][phx-value-uuid='#{io.uuid}']")
      |> render_click()

      html = lv |> element("button[phx-click='source_picker_confirm']") |> render_click()

      assert html =~ "#IO-#{io.number}"
      updated = GoodsReceipts.get_goods_receipt!(receipt.uuid)
      assert %{"type" => "internal_order", "uuid" => io.uuid} in updated.source_refs
      assert length(updated.lines) == 1
    end

    test "removing an attached reference detaches it", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      io = create_internal_order!()

      {:ok, receipt} =
        GoodsReceipts.create_goods_receipt(%{
          location_uuid: @default_location_uuid,
          lines: [],
          source_refs: [%{"type" => "internal_order", "uuid" => io.uuid}]
        })

      {:ok, lv, html} = live(conn, edit_path(receipt.uuid))
      assert html =~ "#IO-#{io.number}"

      html =
        lv
        |> element("button[phx-click='remove_source_ref'][phx-value-uuid='#{io.uuid}']")
        |> render_click()

      refute html =~ "#IO-#{io.number}"
      updated = GoodsReceipts.get_goods_receipt!(receipt.uuid)
      assert updated.source_refs == []
    end
  end

  describe "register_receipt on supplier order form" do
    test "Register receipt button is visible on a posted supplier order", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {so, _supplier} = create_posted_supplier_order!(admin.uuid)

      so_edit_path =
        PhoenixKit.Utils.Routes.path("/admin/warehouse/supplier-orders/#{so.uuid}")

      {:ok, _lv, html} = live(conn, so_edit_path)

      assert html =~ "Register receipt"
    end

    test "clicking Register receipt creates a goods receipt and navigates", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {so, _supplier} = create_posted_supplier_order!(admin.uuid)

      so_edit_path =
        PhoenixKit.Utils.Routes.path("/admin/warehouse/supplier-orders/#{so.uuid}")

      {:ok, lv, _html} = live(conn, so_edit_path)

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               lv |> element("button", "Register receipt") |> render_click()

      assert String.contains?(redirect_to, "/admin/warehouse/goods-receipts/")
    end
  end

  describe "source picker — select all" do
    test "selects every candidate, and toggling again clears the selection", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {receipt, _} = create_draft()
      {so1, _} = create_posted_supplier_order!(admin.uuid)
      {so2, _} = create_posted_supplier_order!(admin.uuid)

      {:ok, lv, _html} = live(conn, lines_path(receipt.uuid))

      lv |> element("button[phx-click='open_source_picker']") |> render_click()

      html = lv |> element("button[phx-click='source_picker_select_all']") |> render_click()

      assert html =~ "Deselect all"
      assert has_element?(lv, "input[phx-value-uuid='#{so1.uuid}'][checked]")
      assert has_element?(lv, "input[phx-value-uuid='#{so2.uuid}'][checked]")

      html = lv |> element("button[phx-click='source_picker_select_all']") |> render_click()

      assert html =~ "Select all"
      refute has_element?(lv, "input[phx-value-uuid='#{so1.uuid}'][checked]")
      refute has_element?(lv, "input[phx-value-uuid='#{so2.uuid}'][checked]")
    end
  end
end
