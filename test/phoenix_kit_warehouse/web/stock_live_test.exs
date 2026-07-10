defmodule PhoenixKitWarehouse.Web.StockLiveTest do
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

  defp path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse")

  test "default view is grouped — no parity toolbar", %{conn: conn} do
    {:ok, _lv, html} = live(login(conn, admin()), path())
    refute html =~ ~s(phx-click="show_column_modal")
  end

  test "switching to flat reveals the parity toolbar and persists the choice", %{conn: conn} do
    a = admin()
    {:ok, lv, _} = live(login(conn, a), path())
    html = render_click(element(lv, ~s([phx-click="set_stock_view"][phx-value-view="flat"])))
    assert html =~ ~s(phx-change="search")
    assert html =~ ~s(phx-click="show_column_modal")

    cfg = PhoenixKitWarehouse.ViewConfigs.get_view_config(a.uuid, "warehouse_stock")
    assert Map.get(cfg, "stock_view") == "flat"

    # persisted: a fresh mount opens directly in flat
    {:ok, _lv2, html2} = live(login(conn, a), path())
    assert html2 =~ ~s(phx-click="show_column_modal")
  end

  test "column modal save persists columns under warehouse_stock", %{conn: conn} do
    a = admin()
    {:ok, lv, _} = live(login(conn, a), path())
    render_click(element(lv, ~s([phx-click="set_stock_view"][phx-value-view="flat"])))
    render_click(lv, "add_column", %{"column_id" => "sku"})

    render_click(lv, "update_table_columns", %{
      "column_order" => "item,catalogue,quantity,total_value,sku"
    })

    cfg = PhoenixKitWarehouse.ViewConfigs.get_view_config(a.uuid, "warehouse_stock")
    assert "sku" in Map.get(cfg, "columns", [])
  end
end
