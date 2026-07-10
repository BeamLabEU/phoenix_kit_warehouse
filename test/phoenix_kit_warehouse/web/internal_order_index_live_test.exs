defmodule PhoenixKitWarehouse.Web.InternalOrderIndexLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders

  @default_location_uuid "00000000-0000-0000-0000-000000000001"

  setup do
    PhoenixKitWarehouse.Test.Repo.delete_all(InternalOrder)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "io-index-#{System.unique_integer([:positive])}@example.com"

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

  defp index_path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse/internal-orders")

  defp create_draft(attrs \\ %{}) do
    {:ok, order} =
      InternalOrders.create_internal_order(
        Map.merge(%{location_uuid: @default_location_uuid}, attrs)
      )

    order
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "internal order index" do
    test "renders the warehouse header with Internal Orders tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "Internal Orders"
    end

    test "clicking New internal order creates a draft and opens the form", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, index_path())

      {:error, {:live_redirect, %{to: new_path}}} =
        lv |> element("a", "New internal order") |> render_click()

      {:error, {:live_redirect, %{to: edit_path}}} = live(conn, new_path)

      assert edit_path =~ ~r{/admin/warehouse/internal-orders/[0-9a-f-]+$}

      {:ok, _form_lv, html} = live(conn, edit_path)

      assert html =~ "Save draft"
    end

    test "lists existing internal orders", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "#IO-#{order.number}"
    end

    test "shows empty state when no orders", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "No internal orders yet"
    end

    test "does not show soft-deleted orders", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      order = create_draft()
      {:ok, _} = InternalOrders.soft_delete_internal_order(order, admin.uuid)

      {:ok, _lv, html} = live(conn, index_path())

      refute html =~ "#IO-#{order.number}"
    end
  end
end
