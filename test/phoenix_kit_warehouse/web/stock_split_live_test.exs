defmodule PhoenixKitWarehouse.Web.StockSplitLiveTest do
  use PhoenixKitWarehouse.LiveCase, async: false
  import Phoenix.LiveViewTest

  defp email, do: "wh-#{System.unique_integer([:positive])}@example.com"

  defp admin do
    {:ok, u} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => email(),
        "password" => "password123456789",
        "first_name" => "W",
        "last_name" => "A"
      })

    {:ok, u} = PhoenixKit.Users.Auth.admin_confirm_user(u)
    {:ok, _} = PhoenixKit.Users.Roles.promote_to_admin(u)
    PhoenixKit.Users.Auth.get_user!(u.uuid)
  end

  defp login(conn, u) do
    t = PhoenixKit.Users.Auth.generate_user_session_token(u)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, t)
  end

  defp stock_path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse")
  defp inv_path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse/inventories")

  test "stock route renders the grouped stock view via StockLive", %{conn: conn} do
    {:ok, _lv, html} = live(login(conn, admin()), stock_path())
    assert html =~ "In stock"
    # grouped view is the default; no parity column-modal button here yet
    refute html =~ ~s(phx-click="show_column_modal")
  end

  test "inventories route still renders its parity toolbar", %{conn: conn} do
    {:ok, _lv, html} = live(login(conn, admin()), inv_path())
    assert html =~ ~s(phx-click="show_column_modal")
  end

  test "the two tabs cross-link to each other's routes", %{conn: conn} do
    {:ok, _lv, html} = live(login(conn, admin()), stock_path())
    assert html =~ inv_path()
  end
end
