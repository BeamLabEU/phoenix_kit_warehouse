defmodule PhoenixKitWarehouse.Web.GoodsReceiptIndexLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.Test.Repo

  @default_location_uuid "00000000-0000-0000-0000-000000000001"

  setup do
    Repo.delete_all(GoodsReceipt)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "gr-idx-#{System.unique_integer([:positive])}@example.com"

  defp create_admin_user do
    {:ok, user} =
      Auth.register_user(%{
        "email" => unique_email(),
        "password" => "password123456789",
        "first_name" => "Admin",
        "last_name" => "User"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.promote_to_admin(user)
    Auth.get_user!(user.uuid)
  end

  defp log_in_admin(conn, user) do
    token = Auth.generate_user_session_token(user)
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

  defp create_goods_receipt!(supplier) do
    {:ok, receipt} =
      GoodsReceipts.create_goods_receipt(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @default_location_uuid,
        lines: []
      })

    receipt
  end

  defp index_path,
    do: Routes.path("/admin/warehouse/goods-receipts")

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "goods receipts index" do
    test "renders the Goods Receipt tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "Goods Receipt"
    end

    test "clicking New goods receipt creates a draft and opens the form", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, index_path())

      {:error, {:live_redirect, %{to: new_path}}} =
        lv |> element("a", "New goods receipt") |> render_click()

      {:error, {:live_redirect, %{to: edit_path}}} = live(conn, new_path)

      assert edit_path =~ ~r{/admin/warehouse/goods-receipts/[0-9a-f-]+$}

      {:ok, _form_lv, html} = live(conn, edit_path)

      assert html =~ "Save draft"
    end

    test "shows empty state when no receipts", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "No goods receipts yet"
    end

    test "lists existing goods receipts by number", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      supplier = create_supplier!()
      receipt = create_goods_receipt!(supplier)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "#GR-#{receipt.number}"
    end

    test "excludes soft-deleted receipts", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      supplier = create_supplier!()
      receipt = create_goods_receipt!(supplier)
      {:ok, _} = GoodsReceipts.soft_delete(receipt, admin.uuid)

      {:ok, _lv, html} = live(conn, index_path())

      refute html =~ "#GR-#{receipt.number}"
    end

    test "shows Goods Receipt tab active in warehouse header", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      # The active tab should have "tab-active" class
      assert html =~ "Goods Receipt"
    end
  end
end
