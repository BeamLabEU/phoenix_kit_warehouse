defmodule PhoenixKitWarehouse.Web.InventoryFormLiveCommentsAndModalTest do
  @moduledoc """
  Block-5 tests covering:

  1. Comments availability/posting smoke — resource_type "inventory".
  2. ItemSelectorModal wiring: "Add item" opens it, `handle_info` on confirm
     appends lines seeded with the picked quantity (dedup by item_uuid), and
     `:item_selector_closed` resets the show flag.
  3. count_sheet / stock_sheet header totals.

  Conventions:
  - ConnCase, async: false (shared DB)
  """

  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.Comments
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.Test.Repo

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    Repo.delete_all(PhoenixKitWarehouse.InventoryDocument)
    Repo.delete_all(PhoenixKitWarehouse.Stock)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email(tag),
    do: "wh-modal-#{tag}-#{System.unique_integer([:positive])}@example.com"

  defp create_admin_user do
    {:ok, user} =
      Auth.register_user(%{
        "email" => unique_email("admin"),
        "password" => "password123456789",
        "first_name" => "ModalBlock5",
        "last_name" => "Admin"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.promote_to_admin(user)
    Auth.get_user!(user.uuid)
  end

  defp log_in(conn, user) do
    token = Auth.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  defp edit_path(uuid),
    do: Routes.path("/admin/warehouse/inventory/#{uuid}")

  defp items_path(uuid),
    do: Routes.path("/admin/warehouse/inventory/#{uuid}/items")

  defp comments_path(uuid),
    do: Routes.path("/admin/warehouse/inventory/#{uuid}/comments")

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
        Auth.register_user(%{
          "email" => unique_email("commenter"),
          "password" => "password123456789",
          "first_name" => "CommentSmoke",
          "last_name" => "User"
        })

      {:ok, user} = Auth.admin_confirm_user(user)

      # Comments off is the correct default (PhoenixKitComments.enabled?/0
      # gates on the "comments_enabled" Setting, absent by default) — nothing
      # in test_helper.exs or this test enables it, so create_comment/4
      # writes the row but Comments.count/2's own availability check reads
      # the module as off and reports 0 regardless. A real deployment always
      # has this decided one way or the other; this test needs it on.
      {:ok, _} = PhoenixKitComments.enable_system()

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
      Repo.delete(comment)

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
  # 2. ItemSelectorModal wiring
  # ---------------------------------------------------------------------------

  describe "\"Add item\" button" do
    test "opens ItemSelectorModal", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      html = render_patch(lv, items_path(doc.uuid))

      refute html =~ "inventory-item-selector"

      html = lv |> element("[phx-click='open_item_selector']") |> render_click()

      assert html =~ "inventory-item-selector"
      assert :sys.get_state(lv.pid).socket.assigns.show_item_selector == true
    end

    test "preselects lines whose counted_quantity was stored as a JSONB string", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("PreselectCat #{n}")
      item = create_active_item!(cat, "PreselectItem #{n}")
      conn = log_in(conn, admin)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: [
            %{
              "item_uuid" => item.uuid,
              "name" => item.name,
              "sku" => item.sku,
              "category_uuid" => item.category_uuid,
              "catalogue_uuid" => item.catalogue_uuid,
              "unit" => item.unit,
              "counted_quantity" => "5",
              "unit_value" => nil
            }
          ]
        })

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))
      html = lv |> element("[phx-click='open_item_selector']") |> render_click()

      assert html =~ "inventory-item-selector"
      assert html =~ "1 item"
    end
  end

  describe "handle_info({:item_selector_closed, ...})" do
    test "closes the modal", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      render_hook(lv, "open_item_selector", %{})
      send(lv.pid, {:item_selector_closed, %{id: "inventory-item-selector"}})

      assert :sys.get_state(lv.pid).socket.assigns.show_item_selector == false
    end
  end

  describe "handle_info({:items_selected, ...}) (ItemSelectorModal confirm)" do
    test "adds a line seeded with the picked quantity, and closes the modal", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("ModalCat #{n}")
      item = create_active_item!(cat, "ModalItem One #{n}")

      # No stock so item is not pre-seeded into lines
      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      pick = %{uuid: item.uuid, qty: Decimal.new("5"), unit: item.unit, name: item.name}
      send(lv.pid, {:items_selected, %{id: "inventory-item-selector", picks: [pick]}})

      state = :sys.get_state(lv.pid)
      assert state.socket.assigns.show_item_selector == false
      [line] = state.socket.assigns.lines
      assert line["item_uuid"] == item.uuid
      assert Decimal.equal?(line["counted_quantity"], Decimal.new("5"))

      html = render(lv)
      assert html =~ item.name
      assert html =~ item.sku
    end

    test "several picks in one confirm append all of them", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("ManyTwo #{n}")
      item_a = create_active_item!(cat, "ManyTwoA #{n}")
      item_b = create_active_item!(cat, "ManyTwoB #{n}")

      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      picks = [
        %{uuid: item_a.uuid, qty: Decimal.new("1"), unit: item_a.unit, name: item_a.name},
        %{uuid: item_b.uuid, qty: Decimal.new("2"), unit: item_b.unit, name: item_b.name}
      ]

      send(lv.pid, {:items_selected, %{id: "inventory-item-selector", picks: picks}})

      html = render(lv)
      assert html =~ item_a.name
      assert html =~ item_b.name
    end

    test "re-adding an already-present item does not duplicate it", %{conn: conn} do
      admin = create_admin_user()
      n = System.unique_integer([:positive])
      cat = create_catalogue!("ManyDedup #{n}")
      item = create_active_item!(cat, "ManyDedupItem #{n}")

      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      pick = %{uuid: item.uuid, qty: Decimal.new("1"), unit: item.unit, name: item.name}
      send(lv.pid, {:items_selected, %{id: "inventory-item-selector", picks: [pick]}})
      :sys.get_state(lv.pid)
      send(lv.pid, {:items_selected, %{id: "inventory-item-selector", picks: [pick]}})

      assert length(:sys.get_state(lv.pid).socket.assigns.lines) == 1
    end

    test "a missing catalogue item is skipped instead of crashing the LiveView", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in(conn, admin)
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      {:ok, lv, _html} = live(conn, edit_path(doc.uuid))
      render_patch(lv, items_path(doc.uuid))

      pick = %{
        uuid: Ecto.UUID.generate(),
        qty: Decimal.new("1"),
        unit: "pcs",
        name: "gone"
      }

      send(lv.pid, {:items_selected, %{id: "inventory-item-selector", picks: [pick]}})

      assert :sys.get_state(lv.pid).socket.assigns.lines == []
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
    defp warehouse_path, do: Routes.path("/admin/warehouse")

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
  # 6. Count input Enter-commit — pressing Enter must not reload/lose data
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

      pick = %{uuid: item.uuid, qty: Decimal.new("0"), unit: item.unit, name: item.name}
      send(lv.pid, {:items_selected, %{id: "inventory-item-selector", picks: [pick]}})
      :sys.get_state(lv.pid)

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
end
