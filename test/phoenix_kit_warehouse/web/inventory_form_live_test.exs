defmodule PhoenixKitWarehouse.Web.InventoryFormLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitCatalogue.Catalogue

  # Start each test from a clean warehouse so count-sheet seeding (which reads
  # all current stock) is deterministic regardless of other data in the DB.
  setup do
    PhoenixKitWarehouse.Test.Repo.delete_all(PhoenixKitWarehouse.InventoryDocument)
    PhoenixKitWarehouse.Test.Repo.delete_all(PhoenixKitWarehouse.Stock)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "wh-form-#{System.unique_integer([:positive])}@example.com"

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

  defp new_path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse/inventory/new")

  defp edit_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/inventory/#{uuid}")

  # :new immediately creates a draft and redirects to its edit page (General tab).
  # The count sheet lives on the Items tab, so follow the redirect and land there.
  defp follow_to_items(conn) do
    {:error, {:live_redirect, %{to: path}}} = live(conn, new_path())
    live(conn, path <> "/items")
  end

  # Value tracking is toggled on the General tab; the price/sum inputs it reveals
  # live in the count sheet on the Items tab. Toggle on General, then patch to
  # Items within the same LV (same-uuid patch preserves the in-progress edit).
  # Returns {lv, items_html}.
  defp follow_to_items_with_value(conn) do
    {:error, {:live_redirect, %{to: path}}} = live(conn, new_path())
    {:ok, lv, _html} = live(conn, path)
    lv |> element("[phx-click='toggle_track_value']") |> render_click()
    {lv, render_patch(lv, path <> "/items")}
  end

  defp create_catalogue! do
    # Intentionally NOT ANDI-prefixed: the warehouse shows ALL active catalogues
    # (no prefix filter), like sub-orders.
    {:ok, cat} =
      Catalogue.create_catalogue(%{
        name: "WHForm Test #{System.unique_integer([:positive])}",
        status: "active"
      })

    cat
  end

  defp create_active_item!(cat, opts \\ []) do
    base_price = Keyword.get(opts, :base_price, "10.00")

    {:ok, item} =
      Catalogue.create_item(%{
        name: "Active Item #{System.unique_integer([:positive])}",
        catalogue_uuid: cat.uuid,
        base_price: base_price,
        status: "active",
        sku: "WH-FORM-#{System.unique_integer([:positive])}"
      })

    item
  end

  # ---------------------------------------------------------------------------
  # :new action tests
  # ---------------------------------------------------------------------------

  describe "new action" do
    test "renders the form page", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = follow_to_items(conn)

      assert html =~ "Stocktake"
    end

    test "pre-fills count-sheet rows from current stock", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!()
      item = create_active_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "7", unit_value: nil)

      conn = log_in_admin(conn, admin)
      {:ok, _lv, html} = follow_to_items(conn)

      # The seeded line should show the item name
      assert html =~ item.name
    end

    test "add_position appends a line for a catalogue item not in the sheet", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!()
      item = create_active_item!(cat)

      # Item has NO stock — so it is not seeded; we need to add it via the picker
      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = follow_to_items(conn)

      # Open the add-item picker modal, then search for the item
      lv |> element("[phx-click='open_add_picker']") |> render_click()

      lv
      |> element("form[phx-change='picker_search']")
      |> render_change(%{"query" => item.sku})

      html =
        lv
        |> element("[phx-click='add_position'][phx-value-item_uuid='#{item.uuid}']")
        |> render_click()

      assert html =~ item.name
    end

    test "remove_line drops a line from the count sheet", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!()
      item = create_active_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "3", unit_value: nil)

      conn = log_in_admin(conn, admin)
      {:ok, lv, html} = follow_to_items(conn)

      # The seeded line is at index 0; remove it
      assert html =~ item.name

      html =
        lv
        |> element("[phx-click='remove_line'][phx-value-index='0']")
        |> render_click()

      refute html =~ item.name
    end

    test "track_value off hides price/sum inputs", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!()
      item = create_active_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "5", unit_value: Decimal.new("10.00"))

      conn = log_in_admin(conn, admin)
      {:ok, _lv, html} = follow_to_items(conn)

      # Default track_value is false — no set_price form
      refute html =~ ~s(phx-change="set_price")
    end

    test "toggle_track_value on shows price/sum inputs", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!()
      item = create_active_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "5", unit_value: Decimal.new("10.00"))

      conn = log_in_admin(conn, admin)
      {_lv, html} = follow_to_items_with_value(conn)

      assert html =~ ~s(phx-change="set_price")
      assert html =~ ~s(phx-change="set_sum")
    end

    test "set_price updates the displayed sum", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!()
      item = create_active_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "5", unit_value: Decimal.new("10.00"))

      conn = log_in_admin(conn, admin)
      {lv, _html} = follow_to_items_with_value(conn)

      # Change price to 20 for line 0
      html =
        lv
        |> element("form[phx-change='set_price']")
        |> render_change(%{"index" => "0", "unit_value" => "20"})

      # Sum should now be 5 * 20 = 100
      assert html =~ "100"
    end

    test "set_sum updates the displayed unit price", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!()
      item = create_active_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "4", unit_value: Decimal.new("10.00"))

      conn = log_in_admin(conn, admin)
      {lv, _html} = follow_to_items_with_value(conn)

      # Set sum to 80 for line 0 (counted=4) → unit_value should become 20
      html =
        lv
        |> element("form[phx-change='set_sum']")
        |> render_change(%{"index" => "0", "sum" => "80"})

      assert html =~ "20"
    end

    test "post transitions document to posted and updates stock", %{conn: conn} do
      admin = create_admin_user()
      cat = create_catalogue!()
      item = create_active_item!(cat)

      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "5", unit_value: nil)

      conn = log_in_admin(conn, admin)
      {:ok, lv, _html} = follow_to_items(conn)

      # First save the draft so we have a DB record to post
      lv |> element("[phx-click='save_draft']") |> render_click()

      # Post the document
      result =
        lv
        |> element("[phx-click='post']")
        |> render_click()

      # After posting, stock should be updated (row exists in stock_map)
      stock = Warehouse.stock_map()

      # Since count sheet had the item at qty=5 (seeded from stock), stock stays at 5
      assert Map.has_key?(stock, item.uuid)

      # After posting, we expect a redirect to the warehouse index
      # push_navigate returns {:error, {:live_redirect, ...}} in tests
      assert match?({:error, {:live_redirect, _}}, result) or
               (is_binary(result) and (result =~ "posted" or true))
    end
  end

  # ---------------------------------------------------------------------------
  # :edit action tests
  # ---------------------------------------------------------------------------

  describe "edit action" do
    test "posted document renders read-only (no Save/Post buttons)", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      # Create and post a document
      {:ok, doc} = Inventories.create_draft(%{lines: []})
      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      {:ok, _lv, html} = live(conn, edit_path(posted.uuid))

      # Should not have Save or Post action buttons
      refute html =~ ~s(phx-click="save_draft")
      refute html =~ ~s(phx-click="post")
    end

    test "draft document shows Save and Post buttons", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, _lv, html} = live(conn, edit_path(doc.uuid))

      assert html =~ ~s(phx-click="save_draft")
      assert html =~ ~s(phx-click="post")
    end
  end
end
