defmodule PhoenixKitWarehouse.Web.ReasonExternalRefLiveTest do
  @moduledoc """
  `reason` (goods issues) and `external_ref` (goods issues, receipts,
  inventories) on the list pages, and `reason` on the goods-issue form.
  """

  use PhoenixKitWarehouse.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Test.Repo
  alias PhoenixKitWarehouse.ViewConfigs

  @location "00000000-0000-0000-0000-000000000001"

  setup %{conn: conn} do
    Repo.delete_all(GoodsIssue)
    Repo.delete_all(GoodsReceipt)
    Repo.delete_all(InventoryDocument)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "reason-ref-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Admin",
        "last_name" => "User"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.promote_to_admin(user)
    admin = Auth.get_user!(user.uuid)

    token = Auth.generate_user_session_token(admin)
    conn = conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)

    {:ok, conn: conn, admin: admin}
  end

  defp show_columns(admin, scope, columns) do
    {:ok, _} = ViewConfigs.merge_view_config(admin.uuid, scope, %{"columns" => columns})
  end

  defp seed!(item, qty) do
    {:ok, _} = StockLedger.upsert_quantity(item, Decimal.new(qty), location_uuid: @location)
  end

  describe "goods issues list" do
    test "shows reason by default and external_ref once the column is switched on", %{
      conn: conn,
      admin: admin
    } do
      item = Ecto.UUID.generate()
      seed!(item, "5")

      {:ok, _} =
        GoodsIssues.create_and_post(
          %{
            location_uuid: @location,
            reason: "damage",
            external_ref: "SHOP-4711",
            lines: [%{"item_uuid" => item, "issued_quantity" => 1}]
          },
          nil
        )

      {:ok, lv, _html} = live(conn, Routes.path("/admin/warehouse/goods-issues"))
      assert has_element?(lv, "#goods-issues-table td", "Damage")
      refute has_element?(lv, "#goods-issues-table td", "SHOP-4711")

      show_columns(admin, "warehouse_goods_issues", ["number", "reason", "external_ref"])

      {:ok, lv, _html} = live(conn, Routes.path("/admin/warehouse/goods-issues"))
      assert has_element?(lv, "#goods-issues-table td", "SHOP-4711")
    end
  end

  describe "goods receipts list" do
    test "shows external_ref when the column is switched on", %{conn: conn, admin: admin} do
      {:ok, _} =
        GoodsReceipts.create_and_post(
          %{
            location_uuid: @location,
            external_ref: "PO-8123",
            lines: [%{"item_uuid" => Ecto.UUID.generate(), "received_quantity" => 1}]
          },
          nil
        )

      show_columns(admin, "warehouse_goods_receipts", ["number", "external_ref"])

      {:ok, lv, _html} = live(conn, Routes.path("/admin/warehouse/goods-receipts"))
      assert has_element?(lv, "table td", "PO-8123")
    end
  end

  describe "inventories list" do
    test "shows external_ref when the column is switched on", %{conn: conn, admin: admin} do
      {:ok, _} =
        Inventories.create_and_post(
          %{
            location_uuid: @location,
            external_ref: "CNT-3141",
            lines: [%{"item_uuid" => Ecto.UUID.generate(), "counted_quantity" => 1}]
          },
          nil
        )

      show_columns(admin, "warehouse_inventories", ["number", "external_ref"])

      {:ok, lv, _html} = live(conn, Routes.path("/admin/warehouse/inventories"))
      assert has_element?(lv, "table td", "CNT-3141")
    end
  end

  describe "goods issue form" do
    test "a draft offers the reason select, preset to production", %{conn: conn} do
      {:ok, issue} = GoodsIssues.create_goods_issue(%{location_uuid: @location})

      {:ok, lv, _html} = live(conn, Routes.path("/admin/warehouse/goods-issues/#{issue.uuid}"))

      assert has_element?(lv, "#gi-reason-select")
      assert has_element?(lv, "#gi-reason-select option[value=production][selected]")

      for reason <- ~w(production sale damage other),
          do: assert(has_element?(lv, "#gi-reason-select option[value=#{reason}]"))
    end

    test "changing the select saves the reason on the draft", %{conn: conn} do
      {:ok, issue} = GoodsIssues.create_goods_issue(%{location_uuid: @location})

      {:ok, lv, _html} = live(conn, Routes.path("/admin/warehouse/goods-issues/#{issue.uuid}"))

      lv |> element("#gi-reason-form") |> render_change(%{"reason" => "sale"})

      assert Repo.get!(GoodsIssue, issue.uuid).reason == "sale"
      assert has_element?(lv, "#gi-reason-select option[value=sale][selected]")
    end

    test "an unknown reason is refused and the draft keeps its reason", %{conn: conn} do
      {:ok, issue} = GoodsIssues.create_goods_issue(%{location_uuid: @location})

      {:ok, lv, _html} = live(conn, Routes.path("/admin/warehouse/goods-issues/#{issue.uuid}"))

      lv |> element("#gi-reason-form") |> render_change(%{"reason" => "gift"})

      assert Repo.get!(GoodsIssue, issue.uuid).reason == "production"
    end

    test "posting a draft whose external_ref a posted issue already holds names the reference",
         %{conn: conn} do
      item = Ecto.UUID.generate()
      seed!(item, "5")
      lines = [%{"item_uuid" => item, "issued_quantity" => 1}]

      {:ok, draft} =
        GoodsIssues.create_goods_issue(%{
          location_uuid: @location,
          external_ref: "SHOP-DUP",
          lines: lines
        })

      {:ok, _posted} =
        GoodsIssues.create_and_post(
          %{location_uuid: @location, external_ref: "SHOP-DUP", lines: lines},
          nil
        )

      {:ok, lv, _html} = live(conn, Routes.path("/admin/warehouse/goods-issues/#{draft.uuid}"))

      html = lv |> element("button", "Issue") |> render_click()

      assert html =~ "External ref SHOP-DUP is already used by a posted goods issue."
      refute html =~ "Failed to post goods issue"
      assert Repo.get!(GoodsIssue, draft.uuid).status == "draft"
    end

    test "a posted issue shows its reason and external_ref read-only", %{conn: conn} do
      item = Ecto.UUID.generate()
      seed!(item, "5")

      {:ok, posted} =
        GoodsIssues.create_and_post(
          %{
            location_uuid: @location,
            reason: "sale",
            external_ref: "SHOP-77",
            lines: [%{"item_uuid" => item, "issued_quantity" => 1}]
          },
          nil
        )

      {:ok, lv, _html} = live(conn, Routes.path("/admin/warehouse/goods-issues/#{posted.uuid}"))

      refute has_element?(lv, "#gi-reason-select")
      assert has_element?(lv, "#gi-reason", "Sale")
      assert has_element?(lv, "#gi-external-ref", "SHOP-77")
    end
  end
end
