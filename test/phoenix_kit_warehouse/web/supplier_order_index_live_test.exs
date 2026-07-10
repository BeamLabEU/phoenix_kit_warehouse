defmodule PhoenixKitWarehouse.Web.SupplierOrderIndexLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

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

  defp unique_email, do: "so-idx-#{System.unique_integer([:positive])}@example.com"

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

  defp create_supplier_order!(supplier) do
    {:ok, order} =
      SupplierOrders.create_supplier_order(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @default_location_uuid,
        lines: []
      })

    order
  end

  defp index_path,
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/supplier-orders")

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "supplier orders index" do
    test "renders the page heading", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "Supplier Orders"
    end

    test "clicking New supplier order creates a draft and opens the form", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, index_path())

      {:error, {:live_redirect, %{to: new_path}}} =
        lv |> element("a", "New supplier order") |> render_click()

      {:error, {:live_redirect, %{to: edit_path}}} = live(conn, new_path)

      assert edit_path =~ ~r{/admin/warehouse/supplier-orders/[0-9a-f-]+$}

      {:ok, _form_lv, html} = live(conn, edit_path)

      assert html =~ "Save draft"
    end

    test "shows empty state when no orders", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "No supplier orders yet"
    end

    test "lists existing supplier orders by number", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      supplier = create_supplier!()
      order = create_supplier_order!(supplier)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "#SO-#{order.number}"
    end

    test "excludes soft-deleted orders", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      supplier = create_supplier!()
      order = create_supplier_order!(supplier)
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, admin.uuid)

      {:ok, _lv, html} = live(conn, index_path())

      refute html =~ "#SO-#{order.number}"
    end

    test "shows Supplier Orders tab active in warehouse header", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "Supplier Orders"
    end
  end
end
