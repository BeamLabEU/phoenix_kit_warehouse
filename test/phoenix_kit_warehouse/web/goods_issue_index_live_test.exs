defmodule PhoenixKitWarehouse.Web.GoodsIssueIndexLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsIssues

  @default_location_uuid "00000000-0000-0000-0000-000000000001"

  setup do
    PhoenixKitWarehouse.Test.Repo.delete_all(GoodsIssue)
    :ok
  end

  defp unique_email, do: "gi-index-#{System.unique_integer([:positive])}@example.com"

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

  defp create_draft! do
    {:ok, issue} =
      GoodsIssues.create_goods_issue(%{
        location_uuid: @default_location_uuid,
        lines: []
      })

    issue
  end

  defp index_path,
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/goods-issues")

  describe "GoodsIssueIndex" do
    test "renders the goods issues list page", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      # Header or page content present
      assert html =~ "Goods" or html =~ "Issue"
    end

    test "clicking New goods issue creates a draft and opens the form", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, index_path())

      {:error, {:live_redirect, %{to: new_path}}} =
        lv |> element("a", "New goods issue") |> render_click()

      {:error, {:live_redirect, %{to: edit_path}}} = live(conn, new_path)

      assert edit_path =~ ~r{/admin/warehouse/goods-issues/[0-9a-f-]+$}

      {:ok, _form_lv, html} = live(conn, edit_path)

      assert html =~ "Save draft"
    end

    test "lists existing goods issues", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft!()

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "#GI-#{issue.number}"
    end

    test "shows empty state when no issues", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "No goods issues yet"
    end

    test "renders status badge for each issue", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      _issue = create_draft!()

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "draft" or html =~ "Draft"
    end

    test "each issue row has a link to the detail page", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      issue = create_draft!()

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ issue.uuid
    end
  end
end
