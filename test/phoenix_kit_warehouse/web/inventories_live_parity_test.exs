defmodule PhoenixKitWarehouse.Web.InventoriesLiveParityTest do
  use PhoenixKitWarehouse.LiveCase, async: false
  import Phoenix.LiveViewTest
  alias PhoenixKitWarehouse.Inventories

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

  defp draft(admin, note) do
    {:ok, doc} =
      Inventories.create_draft(%{created_by_uuid: admin.uuid, note: note, lines: []})

    doc
  end

  defp inv_path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse/inventories")
  defp stock_path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse")

  test "inventories tab renders the parity toolbar", %{conn: conn} do
    a = admin()
    draft(a, "alpha")
    {:ok, _lv, html} = live(login(conn, a), inv_path())
    assert html =~ ~s(phx-change="search")
    assert html =~ ~s(phx-change="set_sort")
    assert html =~ ~s(phx-click="show_column_modal")
  end

  test "global search narrows the documents by note", %{conn: conn} do
    a = admin()
    d1 = draft(a, "alpha-note")
    d2 = draft(a, "beta-note")
    {:ok, lv, _} = live(login(conn, a), inv_path())

    html = render_change(element(lv, ~s(form[phx-change="search"])), %{"search" => "alpha"})
    assert html =~ "/admin/warehouse/inventory/#{d1.uuid}"
    refute html =~ "/admin/warehouse/inventory/#{d2.uuid}"

    html = render_change(element(lv, ~s(form[phx-change="search"])), %{"search" => ""})
    assert html =~ "/admin/warehouse/inventory/#{d2.uuid}"
  end

  test "clicking a sortable header toggles sort and shows a chevron", %{conn: conn} do
    a = admin()
    draft(a, "x")
    {:ok, lv, _} = live(login(conn, a), inv_path())
    html = render_click(element(lv, ~s(button[phx-value-by="number"])))
    assert html =~ "hero-chevron"
  end

  test "column modal persists selected columns under warehouse_inventories scope", %{conn: conn} do
    a = admin()
    draft(a, "x")
    {:ok, lv, _} = live(login(conn, a), inv_path())

    render_click(element(lv, ~s(button[phx-click="show_column_modal"])))
    render_click(lv, "add_column", %{"column_id" => "lines_count"})

    render_click(lv, "update_table_columns", %{
      "column_order" => "number,date,status,note,lines_count"
    })

    config = PhoenixKitWarehouse.ViewConfigs.get_view_config(a.uuid, "warehouse_inventories")
    assert "lines_count" in Map.get(config, "columns", [])
  end

  test "stock tab still renders the grouped sheet (untouched, column-mgmt inert)", %{conn: conn} do
    a = admin()
    {:ok, _lv, html} = live(login(conn, a), stock_path())
    assert html =~ "In stock"
    # No parity toolbar on the stock tab.
    refute html =~ ~s(phx-click="show_column_modal")
  end
end
