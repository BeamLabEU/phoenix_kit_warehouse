defmodule PhoenixKitWarehouse.API.StoredLinesRenderTest do
  @moduledoc """
  The lines of a posted API document show the product's name and SKU in the
  Warehouse pages (a line without them would print "—").
  """
  use PhoenixKitWarehouse.LiveCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWarehouse.API.Write

  setup %{conn: conn} do
    {:ok, admin} =
      Auth.register_user(%{
        "email" => "api-render-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Admin",
        "last_name" => "User"
      })

    {:ok, admin} = Auth.admin_confirm_user(admin)
    {:ok, _} = Roles.promote_to_admin(admin)
    admin = Auth.get_user!(admin.uuid)

    token = Auth.generate_user_session_token(admin)
    conn = conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)

    %{locations: [first | _]} = warehouses!(1)
    %{conn: conn, admin: admin, first: first, item: item!(shop_catalogue!())}
  end

  defp line(item, quantity), do: %{"ref" => %{"id" => item.uuid}, "quantity" => quantity}

  test "a posted goods receipt shows each line's name and sku", %{
    conn: conn,
    admin: admin,
    item: item
  } do
    assert {:ok, %{"document" => %{"id" => id}}} =
             Write.receive_stock(%{"lines" => [line(item, "2")]}, ctx(admin))

    {:ok, _view, html} = live(conn, Routes.path("/admin/warehouse/goods-receipts/#{id}/lines"))

    assert html =~ item.name
    assert html =~ item.sku
  end

  test "a posted goods issue shows each line's name and sku", %{
    conn: conn,
    admin: admin,
    first: first,
    item: item
  } do
    seed!(item.uuid, "5", first.uuid)

    assert {:ok, %{"document" => %{"id" => id}}} =
             Write.issue_stock(%{"reason" => "sale", "lines" => [line(item, "2")]}, ctx(admin))

    {:ok, _view, html} = live(conn, Routes.path("/admin/warehouse/goods-issues/#{id}/lines"))

    assert html =~ item.name
    assert html =~ item.sku
  end
end
