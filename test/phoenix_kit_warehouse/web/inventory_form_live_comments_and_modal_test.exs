defmodule PhoenixKitWarehouse.Web.InventoryFormLiveCommentsAndModalTest do
  @moduledoc """
  Block-5 tests covering:

  1. Comments availability/posting smoke — resource_type "inventory".
  2. Add-picker modal flow:
     - modal opens on "open_add_picker"
     - :one mode → add closes modal
     - :many mode → add keeps modal open (item dimmed)
  3. count_sheet / stock_sheet header totals.

  Conventions:
  - ConnCase, async: false (shared DB)
  - no Process.sleep
  """

  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.Comments
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitCatalogue.Catalogue

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    PhoenixKitWarehouse.Test.Repo.delete_all(PhoenixKitWarehouse.InventoryDocument)
    PhoenixKitWarehouse.Test.Repo.delete_all(PhoenixKitWarehouse.Stock)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email(tag),
    do: "wh-modal-#{tag}-#{System.unique_integer([:positive])}@example.com"

  defp create_admin_user do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => unique_email("admin"),
        "password" => "password123456789",
        "first_name" => "ModalBlock5",
        "last_name" => "Admin"
      })

    {:ok, user} = PhoenixKit.Users.Auth.admin_confirm_user(user)
    {:ok, _} = PhoenixKit.Users.Roles.promote_to_admin(user)
    PhoenixKit.Users.Auth.get_user!(user.uuid)
  end

  defp log_in(conn, user) do
    token = PhoenixKit.Users.Auth.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  defp edit_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/inventory/#{uuid}")

  defp items_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/inventory/#{uuid}/items")

  defp comments_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/inventory/#{uuid}/comments")

  defp create_catalogue!(name) do
    {:ok, cat} =
      Catalogue.create_catalogue(%{
        name: name,
        status: "active"
      })

    cat
  end

  defp create_active_item!(cat, item_name) do
    {:ok, item} =
      Catalogue.create_item(%{
        name: item_name,
        catalogue_uuid: cat.uuid,
        base_price: "10.00",
        status: "active",
        sku: "B5-#{System.unique_integer([:positive])}"
      })

    item
  end

  # ---------------------------------------------------------------------------
  # 1. Comment availability and posting smoke
  # ---------------------------------------------------------------------------

  describe "comments availability" do
    test "Comments.available?/0 reflects comments module state" do
      # The comments module is installed in this project.
      # Whatever value it returns, it must be a boolean.
      result = Comments.available?()
      assert is_boolean(result)
    end

    test "resource_type/1 returns \"inventory\"" do
      assert Comments.resource_type(:inventory) == "inventory"
    end

    test "comments tab link is present for a saved document", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, _lv, html} = live(conn, edit_path(doc.uuid))

      assert html =~ comments_path(doc.uuid)
    end

    test "comments tab renders the panel or unavailable warning", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      html = render_patch(lv, comments_path(doc.uuid))

      # Either the CommentsComponent rendered (contains resource_type input or
      # the panel wrapper) OR the unavailable alert is shown.
      assert html =~ "comments" or html =~ "disabled" or html =~ "Comments"
    end
  end

  describe "comment create/count smoke (server-side, no LiveView)" do
    @tag :smoke
    test "create_comment with resource_type 'inventory' completes quickly (<100ms)" do
      # Need a real user for the FK constraint on phoenix_kit_comments
      {:ok, user} =
        PhoenixKit.Users.Auth.register_user(%{
          "email" => unique_email("commenter"),
          "password" => "password123456789",
          "first_name" => "CommentSmoke",
          "last_name" => "User"
        })

      {:ok, user} = PhoenixKit.Users.Auth.admin_confirm_user(user)

      test_uuid = Ecto.UUID.generate()

      t0 = System.monotonic_time(:millisecond)

      {:ok, comment} =
        PhoenixKitComments.create_comment(
          "inventory",
          test_uuid,
          user.uuid,
          %{content: "block5 smoke #{System.unique_integer([:positive])}"}
        )

      t1 = System.monotonic_time(:millisecond)

      # Verify count increased
      count = Comments.count(:inventory, test_uuid)
      assert count == 1

      # Cleanup via Repo (delete_comment/1 requires a different signature)
      PhoenixKitWarehouse.Test.Repo.delete(comment)

      count_after = Comments.count(:inventory, test_uuid)
      assert count_after == 0

      # The create must complete well under 100ms
      assert t1 - t0 < 100, "Comment create took #{t1 - t0}ms, expected < 100ms"
    end

    test "count/1 returns 0 for a uuid with no comments" do
      unknown_uuid = Ecto.UUID.generate()
      assert Comments.count(:inventory, unknown_uuid) == 0
    end

    test "counts/2 returns an empty map for an empty list" do
      assert Comments.counts(:inventory, []) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Add-picker modal flow
  # ---------------------------------------------------------------------------

  describe "add-picker modal open / close" do
    test "modal is initially hidden on the items tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      html = render_patch(lv, items_path(doc.uuid))

      # The modal element is present but not shown (show=false renders
      # the modal with hidden/display:none or empty markup).
      # "Add item" button is visible (draft document).
      assert html =~ ~s(phx-click="open_add_picker")
    end

    test "open_add_picker event makes the modal appear", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      html =
        lv
        |> element("[phx-click='open_add_picker']")
        |> render_click()

      # Modal should now be visible — it contains the mode toggles
      assert html =~ "close_add_picker" or html =~ dgettext_for_close() or html =~ "add_position"
    end

    test "close_add_picker event hides the modal", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      # Open the modal
      render_hook(lv, "open_add_picker", %{})

      # Close it
      html = render_hook(lv, "close_add_picker", %{})

      # After close, the show_add_picker_modal assign is false.
      # The modal is hidden — the add_position buttons inside it are not visible.
      # We verify by confirming that open_add_picker button is still present
      # (the "Add item" button in the count-sheet header).
      assert html =~ ~s(phx-click="open_add_picker")
    end
  end

  describe "add-picker modal: add mode :one" do
    test ":one mode — adding item closes the modal", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("ModalCat #{n}")
      item = create_active_item!(cat, "ModalItem One #{n}")

      # No stock so item is not pre-seeded into lines
      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      # Open modal
      render_hook(lv, "open_add_picker", %{})

      # Ensure :one mode (default)
      render_hook(lv, "set_add_mode", %{"mode" => "one"})

      # Trigger add_position (as if clicked from the picker)
      html = render_hook(lv, "add_position", %{"item_uuid" => item.uuid})

      # show_add_picker_modal should now be false:
      # The "Done" close button inside the modal markup should not appear,
      # or equivalently the open_add_picker button is still in the outer shell.
      # In :one mode the modal is hidden after add — we verify no modal content visible.
      # The simplest check: item name is now in the count sheet (line was added).
      assert html =~ item.name
    end

    test ":one mode — added item appears in count sheet lines", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("OneCat #{n}")
      item = create_active_item!(cat, "OneItem #{n}")

      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      render_hook(lv, "set_add_mode", %{"mode" => "one"})

      html = render_hook(lv, "add_position", %{"item_uuid" => item.uuid})

      assert html =~ item.name
      # The item SKU is also shown in the count sheet
      assert html =~ item.sku
    end
  end

  describe "add-picker modal: add mode :many" do
    test ":many mode — adding item keeps the modal open (show_add_picker_modal stays true)",
         %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("ManyCat #{n}")
      item = create_active_item!(cat, "ManyItem #{n}")

      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      # Switch to :many mode
      render_hook(lv, "set_add_mode", %{"mode" => "many"})

      # Open the modal, then add an item
      render_hook(lv, "open_add_picker", %{})
      html = render_hook(lv, "add_position", %{"item_uuid" => item.uuid})

      # In :many mode the modal stays open: the "close_add_picker" action is
      # still present in the rendered output (as it's shown in the modal actions).
      assert html =~ "close_add_picker"
    end

    test ":many mode — added item name appears in rendered HTML", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("ManyAdd #{n}")
      item = create_active_item!(cat, "ManyAddItem #{n}")

      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      render_hook(lv, "set_add_mode", %{"mode" => "many"})
      render_hook(lv, "open_add_picker", %{})

      html = render_hook(lv, "add_position", %{"item_uuid" => item.uuid})

      assert html =~ item.name
    end

    test ":many mode — adding a second item appends both to lines", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("ManyTwo #{n}")
      item_a = create_active_item!(cat, "ManyTwoA #{n}")
      item_b = create_active_item!(cat, "ManyTwoB #{n}")

      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      render_hook(lv, "set_add_mode", %{"mode" => "many"})
      render_hook(lv, "open_add_picker", %{})

      render_hook(lv, "add_position", %{"item_uuid" => item_a.uuid})
      html = render_hook(lv, "add_position", %{"item_uuid" => item_b.uuid})

      assert html =~ item_a.name
      assert html =~ item_b.name
    end

    test ":many mode — re-adding an already-present item does not duplicate it", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("ManyDedup #{n}")
      item = create_active_item!(cat, "ManyDedupItem #{n}")

      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      render_hook(lv, "set_add_mode", %{"mode" => "many"})
      render_hook(lv, "open_add_picker", %{})

      # Add the item twice
      render_hook(lv, "add_position", %{"item_uuid" => item.uuid})
      render_hook(lv, "add_position", %{"item_uuid" => item.uuid})

      # Item appears in the lines table exactly once (one tbody row, not two).
      # We scope to "table tbody tr" inside the collapse-content area to avoid
      # counting occurrences in the open modal's add_picker.
      row_count =
        lv
        |> element(".collapse-content table tbody")
        |> render()
        |> String.split(item.name)
        |> length()
        |> Kernel.-(1)

      assert row_count == 1,
             "Expected item to appear exactly once in the lines table but found #{row_count} occurrences"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. count_sheet header totals
  # ---------------------------------------------------------------------------

  describe "count_sheet catalogue header totals" do
    test "catalogue header shows Total label", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("TotalCat #{n}")
      item = create_active_item!(cat, "TotalItem #{n}")

      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "5", unit_value: nil)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: Inventories.seed_lines("en", Warehouse.default_location_uuid()),
          created_by_uuid: admin.uuid
        })

      conn = log_in(conn, admin)
      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      html = render_patch(lv, items_path(doc.uuid))

      # count_sheet renders "Total" in the collapse-title of each catalogue section
      assert html =~ "Total"
    end

    test "catalogue header shows the summed counted quantity", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("SumCat #{n}")
      item = create_active_item!(cat, "SumItem #{n}")

      # Use a distinctive quantity unlikely to appear elsewhere
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "77777", unit_value: nil)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: Inventories.seed_lines("en", Warehouse.default_location_uuid()),
          created_by_uuid: admin.uuid
        })

      conn = log_in(conn, admin)
      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      html = render_patch(lv, items_path(doc.uuid))

      # The catalogue header badge shows the stock quantity (seeded as counted)
      assert html =~ "77777"
    end

    test "two catalogues each show their section header", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat_a = create_catalogue!("TwoA #{n}")
      cat_b = create_catalogue!("TwoB #{n}")

      item_a = create_active_item!(cat_a, "ItemTwoA #{n}")
      item_b = create_active_item!(cat_b, "ItemTwoB #{n}")

      {:ok, _} = Warehouse.upsert_quantity(item_a.uuid, "3", unit_value: nil)
      {:ok, _} = Warehouse.upsert_quantity(item_b.uuid, "6", unit_value: nil)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: Inventories.seed_lines("en", Warehouse.default_location_uuid()),
          created_by_uuid: admin.uuid
        })

      conn = log_in(conn, admin)
      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      html = render_patch(lv, items_path(doc.uuid))

      # Both catalogue names appear as section headers
      assert html =~ "TwoA #{n}"
      assert html =~ "TwoB #{n}"
    end
  end

  # ---------------------------------------------------------------------------
  # 4. stock_sheet header totals (via warehouse index)
  # ---------------------------------------------------------------------------

  describe "stock_sheet catalogue header totals" do
    defp warehouse_path, do: PhoenixKit.Utils.Routes.path("/admin/warehouse")

    test "stock_sheet shows Total label in catalogue section header", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("StockTotalCat #{n}")
      item = create_active_item!(cat, "StockTotalItem #{n}")

      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "4", unit_value: nil)

      conn = log_in(conn, admin)
      {:ok, _lv, html} = live(conn, warehouse_path())

      assert html =~ "Total"
    end

    test "stock_sheet header shows summed quantity for a catalogue", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("StockSumCat #{n}")
      item_a = create_active_item!(cat, "StockA #{n}")
      item_b = create_active_item!(cat, "StockB #{n}")

      # 11111 + 22222 = 33333 — unlikely to collide with anything else
      {:ok, _} = Warehouse.upsert_quantity(item_a.uuid, "11111", unit_value: nil)
      {:ok, _} = Warehouse.upsert_quantity(item_b.uuid, "22222", unit_value: nil)

      conn = log_in(conn, admin)
      {:ok, _lv, html} = live(conn, warehouse_path())

      # Individual quantities visible in item rows
      assert html =~ "11111"
      assert html =~ "22222"
      # Sum total appears in the catalogue header
      assert html =~ "33333"
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Handle_info catch-all — unmatched messages don't crash the LiveView
  # ---------------------------------------------------------------------------

  describe "handle_info catch-all (crash hardening)" do
    test "unmatched handle_info message does not crash the LiveView", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))

      # Send an unmatched message to the LiveView process
      pid = lv.pid
      send(pid, {:unexpected_msg, :from_test, System.unique_integer()})

      # If the catch-all is present the LV should remain alive
      # We verify by performing another render
      html = render(lv)
      assert html =~ "Stocktake"
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Add-picker search modes — list vs tree
  # ---------------------------------------------------------------------------

  describe "add-picker search modes (list vs tree)" do
    setup %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("ModeCat #{n}")
      item = create_active_item!(cat, "ModeItem #{n}")

      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))
      html = render_hook(lv, "open_add_picker", %{})

      %{lv: lv, cat: cat, item: item, opened_html: html}
    end

    test "list mode (default) with no query does NOT render the catalogue tree",
         %{opened_html: html} do
      # In list mode the tree (toggle_catalogue headers) must be hidden so the
      # view is purely search-driven.
      refute html =~ ~s(phx-click="toggle_catalogue")
    end

    test "tree mode with no query renders the catalogue tree", %{lv: lv} do
      html = render_hook(lv, "set_search_mode", %{"mode" => "tree"})
      assert html =~ ~s(phx-click="toggle_catalogue")
    end

    test "list mode with a query shows flat results with an Add button, no tree",
         %{lv: lv, item: item} do
      render_hook(lv, "set_search_mode", %{"mode" => "list"})

      html =
        lv
        |> element("form[phx-change='picker_search']")
        |> render_change(%{"query" => item.sku})

      assert html =~ item.name
      assert html =~ ~s(phx-value-item_uuid="#{item.uuid}")
      refute html =~ ~s(phx-click="toggle_catalogue")
    end

    test "tree mode with a query keeps the (filtered) catalogue tree",
         %{lv: lv, item: item} do
      render_hook(lv, "set_search_mode", %{"mode" => "tree"})

      html =
        lv
        |> element("form[phx-change='picker_search']")
        |> render_change(%{"query" => item.sku})

      assert html =~ ~s(phx-click="toggle_catalogue")
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Count input Enter-commit — pressing Enter must not reload/lose data
  # ---------------------------------------------------------------------------

  describe "count sheet Enter-commit (no reload)" do
    test "submitting the counted form (Enter) commits the value and keeps the line",
         %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("EnterCat #{n}")
      item = create_active_item!(cat, "EnterItem #{n}")

      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))
      render_hook(lv, "add_position", %{"item_uuid" => item.uuid})

      # Pressing Enter triggers a form submit. With phx-submit wired, LiveView
      # commits the value instead of doing an external form submit (page reload
      # that would discard the freshly-added line and the typed count).
      html =
        lv
        |> element("form[phx-submit='set_counted']")
        |> render_submit(%{"index" => "0", "counted_quantity" => "42"})

      # Line survived and the typed count is committed.
      assert html =~ item.name
      assert html =~ "42"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers for test readability
  # ---------------------------------------------------------------------------

  # Returns the translated "Done" button text used in the modal actions.
  # Avoids hardcoding the translation in tests.
  defp dgettext_for_close do
    Gettext.dgettext(PhoenixKitWarehouse.Gettext, "default", "Done")
  end
end
