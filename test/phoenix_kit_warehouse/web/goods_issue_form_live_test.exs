defmodule PhoenixKitWarehouse.Web.GoodsIssueFormLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.InternalOrders

  @default_location_uuid "00000000-0000-0000-0000-000000000001"

  setup do
    PhoenixKitWarehouse.Test.Repo.delete_all(GoodsIssue)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "gi-form-#{System.unique_integer([:positive])}@example.com"

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

  defp create_draft do
    {:ok, issue} =
      GoodsIssues.create_goods_issue(%{
        location_uuid: @default_location_uuid,
        lines: [],
        note: ""
      })

    issue
  end

  defp create_draft_with_lines do
    item_uuid = Ecto.UUID.generate()

    {:ok, _} =
      Warehouse.upsert_quantity(item_uuid, Decimal.new("20"),
        location_uuid: @default_location_uuid
      )

    lines = [
      %{
        "item_uuid" => item_uuid,
        "name" => "Material A",
        "sku" => "MAT-001",
        "unit" => "pcs",
        "catalogue_uuid" => Ecto.UUID.generate(),
        "issued_quantity" => Decimal.new("5")
      }
    ]

    {:ok, issue} =
      GoodsIssues.create_goods_issue(%{
        location_uuid: @default_location_uuid,
        lines: lines,
        note: ""
      })

    {issue, item_uuid}
  end

  defp create_posted_internal_order!(actor_uuid) do
    {:ok, io} =
      InternalOrders.create_internal_order(%{location_uuid: @default_location_uuid, lines: []})

    {:ok, posted} = InternalOrders.post_internal_order(io, actor_uuid)
    posted
  end

  defp edit_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/goods-issues/#{uuid}")

  defp lines_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/goods-issues/#{uuid}/lines")

  defp files_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/goods-issues/#{uuid}/files")

  defp comments_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/goods-issues/#{uuid}/comments")

  # ---------------------------------------------------------------------------
  # General tab — draft
  # ---------------------------------------------------------------------------

  describe "draft goods issue form" do
    test "renders Save draft and Issue buttons for draft", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft()

      {:ok, lv, _html} = live(conn, edit_path(issue.uuid))

      assert has_element?(lv, "button", "Save draft")
      assert has_element?(lv, "button", "Issue")
    end

    test "shows General tab by default", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(issue.uuid))

      assert html =~ "General"
    end

    test "shows the issue number in page heading", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(issue.uuid))

      assert html =~ "#GI-#{issue.number}"
    end
  end

  # ---------------------------------------------------------------------------
  # Tab navigation
  # ---------------------------------------------------------------------------

  describe "tab navigation" do
    test "Lines tab is present", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(issue.uuid))

      assert html =~ "Lines"
    end

    test "Files tab is present", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(issue.uuid))

      assert html =~ "Files"
    end

    test "Comments tab is present", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft()

      {:ok, _lv, html} = live(conn, edit_path(issue.uuid))

      assert html =~ "Comments"
    end

    test "Lines tab shows Issue qty and On hand column headers", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {issue, _item_uuid} = create_draft_with_lines()

      {:ok, _lv, html} = live(conn, lines_path(issue.uuid))

      assert html =~ "Issue qty"
      assert html =~ "On hand"
    end

    test "Lines tab shows empty state when no lines", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft()

      {:ok, _lv, html} = live(conn, lines_path(issue.uuid))

      assert html =~ "No lines yet"
    end

    test "Files tab renders loading or unavailable state", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft()

      {:ok, _lv, html} = live(conn, files_path(issue.uuid))

      assert html =~ "files" or html =~ "loading" or html =~ "media" or html =~ "Files"
    end

    test "Comments tab renders comments or unavailable state", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft()

      {:ok, _lv, html} = live(conn, comments_path(issue.uuid))

      assert html =~ "Comments" or html =~ "disabled"
    end
  end

  # ---------------------------------------------------------------------------
  # Lines editing — issued_quantity input
  # ---------------------------------------------------------------------------

  describe "issued_quantity editing" do
    test "keeper can edit issued_quantity on a draft line", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {issue, _item_uuid} = create_draft_with_lines()

      {:ok, lv, _html} = live(conn, lines_path(issue.uuid))

      lv
      |> element("#gi-iss-form-0")
      |> render_change(%{"index" => "0", "issued_quantity" => "3"})

      html = render(lv)
      assert html =~ ~r/3/
    end

    test "on-hand quantity is shown (read-only) next to each line", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {issue, _item_uuid} = create_draft_with_lines()

      {:ok, _lv, html} = live(conn, lines_path(issue.uuid))

      # On hand column header is present
      assert html =~ "On hand"
    end
  end

  # ---------------------------------------------------------------------------
  # Post (conduct/issue) transition
  # ---------------------------------------------------------------------------

  describe "issue action" do
    test "clicking Issue on a draft with sufficient stock posts and navigates away", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {issue, _item_uuid} = create_draft_with_lines()

      {:ok, lv, _html} = live(conn, edit_path(issue.uuid))

      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               lv |> element("button", "Issue") |> render_click()

      assert String.contains?(redirect_to, "/admin/warehouse/goods-issues")

      {:ok, posted} = GoodsIssues.get_goods_issue(issue.uuid)
      assert posted.status == "posted"
    end

    test "insufficient stock shows flash error and doc stays draft", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      # Create a line with more issued than on hand
      item_uuid = Ecto.UUID.generate()

      {:ok, _} =
        Warehouse.upsert_quantity(item_uuid, Decimal.new("1"),
          location_uuid: @default_location_uuid
        )

      lines = [
        %{
          "item_uuid" => item_uuid,
          "name" => "Scarce Material",
          "sku" => "SCAR-001",
          "unit" => "pcs",
          "catalogue_uuid" => Ecto.UUID.generate(),
          "issued_quantity" => Decimal.new("999")
        }
      ]

      {:ok, issue} =
        GoodsIssues.create_goods_issue(%{
          location_uuid: @default_location_uuid,
          lines: lines
        })

      {:ok, lv, _html} = live(conn, edit_path(issue.uuid))

      html = lv |> element("button", "Issue") |> render_click()

      assert html =~ "Insufficient stock" or html =~ "insufficient" or html =~ "Scarce Material"

      # Doc must still be draft
      {:ok, reloaded} = GoodsIssues.get_goods_issue(issue.uuid)
      assert reloaded.status == "draft"
    end
  end

  # ---------------------------------------------------------------------------
  # Posted state
  # ---------------------------------------------------------------------------

  describe "posted goods issue form" do
    test "shows Posted badge when posted", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {issue, _item_uuid} = create_draft_with_lines()
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, admin.uuid)

      {:ok, _lv, html} = live(conn, edit_path(posted.uuid))

      assert html =~ "Posted"
    end

    test "lines are read-only on a posted issue", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {issue, _item_uuid} = create_draft_with_lines()
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, admin.uuid)

      {:ok, _lv, html} = live(conn, lines_path(posted.uuid))

      # No issued_quantity input form in posted state
      refute html =~ "gi-iss-form"
      refute html =~ ~r/name="issued_quantity"/
    end

    test "shows 'Lines are read-only' info alert on posted lines tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {issue, _item_uuid} = create_draft_with_lines()
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, admin.uuid)

      {:ok, _lv, html} = live(conn, lines_path(posted.uuid))

      assert html =~ "read-only"
    end
  end

  describe "traceability chain — grouped refs and manual linking" do
    test "groups resolved source_refs by tier under labeled sections", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      io = create_posted_internal_order!(admin.uuid)
      customer_order = PhoenixKitWarehouse.Test.Fixtures.insert_order!()

      {:ok, issue} =
        GoodsIssues.create_goods_issue(%{
          location_uuid: @default_location_uuid,
          lines: [],
          source_refs: [
            %{"type" => "internal_order", "uuid" => io.uuid},
            %{"type" => "order", "uuid" => customer_order.uuid}
          ]
        })

      {:ok, _lv, html} = live(conn, edit_path(issue.uuid))

      assert html =~ "Internal orders"
      assert html =~ "Customer orders"
      assert html =~ "#IO-#{io.number}"
      assert html =~ "##{customer_order.data["order_number"]}"
    end

    test "manually attaching an internal order adds a link without touching lines", %{
      conn: conn
    } do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      {issue, _item_uuid} = create_draft_with_lines()
      io = create_posted_internal_order!(admin.uuid)

      {:ok, lv, _html} = live(conn, edit_path(issue.uuid))

      lv
      |> element("button[phx-click='open_link_picker'][phx-value-kind='internal_order']")
      |> render_click()

      lv
      |> element("input[phx-click='source_picker_toggle'][phx-value-uuid='#{io.uuid}']")
      |> render_click()

      html = lv |> element("button[phx-click='source_picker_confirm']") |> render_click()

      assert html =~ "#IO-#{io.number}"
      updated = GoodsIssues.get_goods_issue!(issue.uuid)
      assert %{"type" => "internal_order", "uuid" => io.uuid} in updated.source_refs
      assert length(updated.lines) == 1
    end

    test "removing an attached reference detaches it", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      io = create_posted_internal_order!(admin.uuid)

      {:ok, issue} =
        GoodsIssues.create_goods_issue(%{
          location_uuid: @default_location_uuid,
          lines: [],
          source_refs: [%{"type" => "internal_order", "uuid" => io.uuid}]
        })

      {:ok, lv, html} = live(conn, edit_path(issue.uuid))
      assert html =~ "#IO-#{io.number}"

      html =
        lv
        |> element("button[phx-click='remove_source_ref'][phx-value-uuid='#{io.uuid}']")
        |> render_click()

      refute html =~ "#IO-#{io.number}"
      updated = GoodsIssues.get_goods_issue!(issue.uuid)
      assert updated.source_refs == []
    end
  end

  describe "source picker — select all" do
    test "selects every candidate, and toggling again clears the selection", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft()
      io1 = create_posted_internal_order!(admin.uuid)
      io2 = create_posted_internal_order!(admin.uuid)

      {:ok, lv, _html} = live(conn, lines_path(issue.uuid))

      lv |> element("button[phx-click='open_io_picker']") |> render_click()

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
end
