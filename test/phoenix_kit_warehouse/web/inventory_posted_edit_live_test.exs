defmodule PhoenixKitWarehouse.Web.InventoryPostedEditLiveTest do
  @moduledoc """
  Tests for posted-document editing behaviour in the InventoryForm LiveView.

  Covers:
  - Admin sees editable controls + «Перепровести» on a posted document.
  - Non-admin sees a read-only view (no correction/repost buttons).
  - correct_document/2 updates lines WITHOUT touching andi_warehouse_stock.
  - repost_document/2 re-applies ABSOLUTE stock quantities and re-stamps
    posted_at / performed_by_uuid.
  - Activity rows land in phoenix_kit_activities for create / draft_saved /
    posted / corrected / reposted.
  """

  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.ActivityLog
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKit.Activity.Entry

  # Clear warehouse-owned tables before each test so count-sheet seeding and
  # stock assertions are deterministic regardless of shared DB state.
  setup do
    PhoenixKitWarehouse.Test.Repo.delete_all(PhoenixKitWarehouse.InventoryDocument)
    PhoenixKitWarehouse.Test.Repo.delete_all(PhoenixKitWarehouse.Stock)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email(tag),
    do: "inv-posted-#{tag}-#{System.unique_integer([:positive])}@example.com"

  defp create_admin_user do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => unique_email("admin"),
        "password" => "password123456789",
        "first_name" => "Posted",
        "last_name" => "Admin"
      })

    {:ok, user} = PhoenixKit.Users.Auth.admin_confirm_user(user)
    {:ok, _} = PhoenixKit.Users.Roles.promote_to_admin(user)
    PhoenixKit.Users.Auth.get_user!(user.uuid)
  end

  defp create_regular_user do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => unique_email("regular"),
        "password" => "password123456789",
        "first_name" => "Posted",
        "last_name" => "Regular"
      })

    {:ok, user} = PhoenixKit.Users.Auth.admin_confirm_user(user)
    PhoenixKit.Users.Auth.get_user!(user.uuid)
  end

  defp log_in(conn, user) do
    token = PhoenixKit.Users.Auth.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  defp edit_path(uuid),
    do: PhoenixKit.Utils.Routes.path("/admin/warehouse/inventory/#{uuid}")

  # Returns the count of phoenix_kit_activities rows for a given resource_uuid
  # and optional action filter.
  defp activity_count(resource_uuid, opts \\ []) do
    action = Keyword.get(opts, :action)

    query =
      from(e in Entry,
        where: e.resource_uuid == ^resource_uuid
      )

    query =
      if action do
        where(query, [e], e.action == ^action)
      else
        query
      end

    PhoenixKitWarehouse.Test.Repo.aggregate(query, :count)
  end

  # ---------------------------------------------------------------------------
  # LiveView access control: admin vs. non-admin on a posted document
  # ---------------------------------------------------------------------------

  describe "posted document — admin sees editable controls" do
    test "admin sees save_correction and repost (Перепровести) buttons on general tab", %{
      conn: conn
    } do
      admin = create_admin_user()

      {:ok, doc} = Inventories.create_draft(%{lines: []})
      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      conn = log_in(conn, admin)
      {:ok, _lv, html} = live(conn, edit_path(posted.uuid))

      assert html =~ ~s(phx-click="save_correction")
      assert html =~ ~s(phx-click="repost")
      assert html =~ "Re-conduct"
    end

    test "admin sees Conducted badge alongside the edit controls", %{conn: conn} do
      admin = create_admin_user()

      {:ok, doc} = Inventories.create_draft(%{lines: []})
      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      conn = log_in(conn, admin)
      {:ok, _lv, html} = live(conn, edit_path(posted.uuid))

      assert html =~ "Conducted"
    end

    test "admin does NOT see Save draft or Conduct buttons on a posted document", %{conn: conn} do
      admin = create_admin_user()

      {:ok, doc} = Inventories.create_draft(%{lines: []})
      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      conn = log_in(conn, admin)
      {:ok, _lv, html} = live(conn, edit_path(posted.uuid))

      refute html =~ ~s(phx-click="save_draft")
      refute html =~ ~s(phx-click="post")
    end
  end

  describe "posted document — non-admin sees read-only view" do
    test "non-admin is redirected away from the admin inventory page (admin-gated route)", %{
      conn: conn
    } do
      # The /admin/warehouse/inventory/:uuid route is behind
      # :phoenix_kit_ensure_admin — a confirmed but non-admin user is redirected.
      regular = create_regular_user()
      conn = log_in(conn, regular)

      admin = create_admin_user()
      {:ok, doc} = Inventories.create_draft(%{lines: []})
      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      # Should redirect (not render the LiveView)
      assert {:error, {:redirect, _}} = live(conn, edit_path(posted.uuid))
    end

    test "non-admin responsibility_field component renders read-only span (no select)", %{
      conn: _conn
    } do
      alias PhoenixKitWarehouse.Web.InventoryFormLive, as: InventoryForm

      html =
        render_component(&InventoryForm.responsibility_field/1,
          label: "Responsible",
          field_name: "performed_by_uuid",
          selected_uuid: nil,
          admin?: false,
          selectable_users: []
        )

      # Non-admin: no <select>, only a <span>
      refute html =~ "<select"
      refute html =~ ~s(name="performed_by_uuid")
      assert html =~ "<span"
    end
  end

  # ---------------------------------------------------------------------------
  # correct_document/2 — updates lines, does NOT touch stock
  # ---------------------------------------------------------------------------

  describe "correct_document/2" do
    test "updates document lines without changing andi_warehouse_stock", %{conn: _conn} do
      admin = create_admin_user()
      item_uuid = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item_uuid, "10", unit_value: Decimal.new("5"))

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: [%{"item_uuid" => item_uuid, "counted_quantity" => "10"}]
        })

      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      stock_before = Warehouse.stock_map()[item_uuid]

      # Correct: change counted_quantity from 10 to 25
      corrected_lines = [%{"item_uuid" => item_uuid, "counted_quantity" => "25"}]
      {:ok, corrected} = Inventories.correct_document(posted, %{lines: corrected_lines})

      # Lines in the document are updated
      line = Enum.find(corrected.lines, &(&1["item_uuid"] == item_uuid))
      assert Decimal.equal?(Warehouse.to_decimal(line["counted_quantity"]), Decimal.new("25"))

      # Stock is UNCHANGED
      stock_after = Warehouse.stock_map()[item_uuid]
      assert Decimal.equal?(stock_after.quantity, stock_before.quantity)
    end

    test "document status remains 'posted' after correction", %{conn: _conn} do
      admin = create_admin_user()

      {:ok, doc} = Inventories.create_draft(%{lines: []})
      {:ok, posted} = Inventories.post_document(doc, admin.uuid)
      {:ok, corrected} = Inventories.correct_document(posted, %{note: "corrected"})

      assert corrected.status == "posted"
    end

    test "correct_document can update multiple lines simultaneously", %{conn: _conn} do
      admin = create_admin_user()
      item1 = Ecto.UUID.generate()
      item2 = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item1, "5", unit_value: nil)
      {:ok, _} = Warehouse.upsert_quantity(item2, "8", unit_value: nil)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: [
            %{"item_uuid" => item1, "counted_quantity" => "5"},
            %{"item_uuid" => item2, "counted_quantity" => "8"}
          ]
        })

      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      new_lines = [
        %{"item_uuid" => item1, "counted_quantity" => "99"},
        %{"item_uuid" => item2, "counted_quantity" => "77"}
      ]

      {:ok, corrected} = Inventories.correct_document(posted, %{lines: new_lines})

      line1 = Enum.find(corrected.lines, &(&1["item_uuid"] == item1))
      line2 = Enum.find(corrected.lines, &(&1["item_uuid"] == item2))

      assert Decimal.equal?(Warehouse.to_decimal(line1["counted_quantity"]), Decimal.new("99"))
      assert Decimal.equal?(Warehouse.to_decimal(line2["counted_quantity"]), Decimal.new("77"))

      # Stock untouched for both items
      assert Decimal.equal?(Warehouse.stock_map()[item1].quantity, Decimal.new("5"))
      assert Decimal.equal?(Warehouse.stock_map()[item2].quantity, Decimal.new("8"))
    end
  end

  # ---------------------------------------------------------------------------
  # repost_document/2 — re-applies ABSOLUTE stock + re-stamps metadata
  # ---------------------------------------------------------------------------

  describe "repost_document/2" do
    test "re-applies ABSOLUTE stock: andi_warehouse_stock.quantity equals corrected counted_quantity",
         %{conn: _conn} do
      admin = create_admin_user()
      item_uuid = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item_uuid, "10", unit_value: nil)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: [%{"item_uuid" => item_uuid, "counted_quantity" => "10"}]
        })

      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      # Correct lines to new quantity (25) without touching stock
      {:ok, corrected} =
        Inventories.correct_document(posted, %{
          lines: [%{"item_uuid" => item_uuid, "counted_quantity" => "25"}]
        })

      assert Decimal.equal?(Warehouse.stock_map()[item_uuid].quantity, Decimal.new("10"))

      # Repost — stock must now reflect the corrected quantity
      {:ok, reposted} = Inventories.repost_document(corrected, admin.uuid)

      stock = Warehouse.stock_map()[item_uuid]
      assert Decimal.equal?(stock.quantity, Decimal.new("25"))
      assert reposted.status == "posted"
    end

    test "repost re-stamps posted_at to a new timestamp", %{conn: _conn} do
      admin = create_admin_user()

      {:ok, doc} = Inventories.create_draft(%{lines: []})
      {:ok, posted} = Inventories.post_document(doc, admin.uuid)
      original_posted_at = posted.posted_at

      # Wait at least 1 second so timestamps differ (utc_datetime precision is seconds)
      # Cannot use Process.sleep — use a monotonic reference instead:
      # We insert a small timestamp offset by patching posted_at directly.
      # Actually, since truncation is to :second and tests run in <1s, we force
      # the original posted_at to be 1 second in the past for a clean comparison.
      old_ts = DateTime.add(original_posted_at, -2, :second)

      PhoenixKitWarehouse.Test.Repo.update_all(
        from(d in PhoenixKitWarehouse.InventoryDocument, where: d.uuid == ^posted.uuid),
        set: [posted_at: old_ts]
      )

      {:ok, stale} = Inventories.get_document(posted.uuid)
      {:ok, reposted} = Inventories.repost_document(stale, admin.uuid)

      # new posted_at is at or after the original
      assert DateTime.compare(reposted.posted_at, stale.posted_at) in [:gt, :eq]
    end

    test "repost re-stamps performed_by_uuid to the new performer", %{conn: _conn} do
      admin = create_admin_user()
      item_uuid = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item_uuid, "5", unit_value: nil)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: [%{"item_uuid" => item_uuid, "counted_quantity" => "5"}]
        })

      {:ok, posted} = Inventories.post_document(doc, admin.uuid)
      assert posted.performed_by_uuid == admin.uuid

      # New performer for repost
      {:ok, admin2} =
        PhoenixKit.Users.Auth.register_user(%{
          "email" => unique_email("admin2"),
          "password" => "password123456789",
          "first_name" => "Second",
          "last_name" => "Admin"
        })

      {:ok, admin2} = PhoenixKit.Users.Auth.admin_confirm_user(admin2)
      {:ok, _} = PhoenixKit.Users.Roles.promote_to_admin(admin2)

      {:ok, reposted} = Inventories.repost_document(posted, admin2.uuid)

      assert reposted.performed_by_uuid == admin2.uuid
    end

    test "repost returns {:error, :not_posted} for a draft document", %{conn: _conn} do
      admin = create_admin_user()
      {:ok, doc} = Inventories.create_draft(%{lines: []})

      assert {:error, :not_posted} = Inventories.repost_document(doc, admin.uuid)
    end

    test "repost with track_value: true updates unit_value in stock", %{conn: _conn} do
      admin = create_admin_user()
      item_uuid = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item_uuid, "3", unit_value: Decimal.new("10"))

      {:ok, doc} =
        Inventories.create_draft(%{
          track_value: true,
          lines: [
            %{"item_uuid" => item_uuid, "counted_quantity" => "3", "unit_value" => "10"}
          ]
        })

      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      # Correct to new qty + price
      {:ok, corrected} =
        Inventories.correct_document(posted, %{
          track_value: true,
          lines: [
            %{"item_uuid" => item_uuid, "counted_quantity" => "7", "unit_value" => "20"}
          ]
        })

      {:ok, _} = Inventories.repost_document(corrected, admin.uuid)

      stock = Warehouse.stock_map()[item_uuid]
      assert Decimal.equal?(stock.quantity, Decimal.new("7"))
      assert Decimal.equal?(stock.unit_value, Decimal.new("20"))
    end
  end

  # ---------------------------------------------------------------------------
  # Activity logging via save_correction and repost LiveView events
  # ---------------------------------------------------------------------------

  describe "activity logging via LiveView events" do
    test "save_correction event logs a warehouse.inventory.corrected activity", %{conn: conn} do
      admin = create_admin_user()

      {:ok, doc} = Inventories.create_draft(%{lines: []})
      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      conn = log_in(conn, admin)
      {:ok, lv, _html} = live(conn, edit_path(posted.uuid))

      before_count = activity_count(posted.uuid, action: "warehouse.inventory.corrected")

      render_hook(lv, "save_correction", %{})

      after_count = activity_count(posted.uuid, action: "warehouse.inventory.corrected")
      assert after_count == before_count + 1
    end

    test "repost event logs a warehouse.inventory.reposted activity", %{conn: conn} do
      admin = create_admin_user()
      item_uuid = Ecto.UUID.generate()

      {:ok, _} = Warehouse.upsert_quantity(item_uuid, "5", unit_value: nil)

      {:ok, doc} =
        Inventories.create_draft(%{
          lines: [%{"item_uuid" => item_uuid, "counted_quantity" => "5"}]
        })

      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      conn = log_in(conn, admin)
      {:ok, lv, _html} = live(conn, edit_path(posted.uuid))

      before_count = activity_count(posted.uuid, action: "warehouse.inventory.reposted")

      render_hook(lv, "repost", %{})

      after_count = activity_count(posted.uuid, action: "warehouse.inventory.reposted")
      assert after_count == before_count + 1
    end
  end

  # ---------------------------------------------------------------------------
  # Activity logging via context functions (unit-level, no LiveView)
  # ---------------------------------------------------------------------------

  describe "ActivityLog — context-level activity rows" do
    test "log_created/2 inserts a warehouse.inventory.created row for the document uuid", %{
      conn: _conn
    } do
      admin = create_admin_user()
      {:ok, doc} = Inventories.create_draft(%{created_by_uuid: admin.uuid, lines: []})

      before_count = activity_count(doc.uuid, action: "warehouse.inventory.created")
      ActivityLog.log_created(doc, actor: admin)
      after_count = activity_count(doc.uuid, action: "warehouse.inventory.created")

      assert after_count == before_count + 1
    end

    test "log_draft_saved/3 inserts a warehouse.inventory.draft_saved row", %{conn: _conn} do
      admin = create_admin_user()
      {:ok, doc} = Inventories.create_draft(%{created_by_uuid: admin.uuid, lines: []})

      before_count = activity_count(doc.uuid, action: "warehouse.inventory.draft_saved")
      ActivityLog.log_draft_saved(doc, %{note: %{from: "", to: "updated"}}, actor: admin)
      after_count = activity_count(doc.uuid, action: "warehouse.inventory.draft_saved")

      assert after_count == before_count + 1
    end

    test "log_posted/2 inserts a warehouse.inventory.posted row", %{conn: _conn} do
      admin = create_admin_user()
      {:ok, doc} = Inventories.create_draft(%{created_by_uuid: admin.uuid, lines: []})
      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      before_count = activity_count(posted.uuid, action: "warehouse.inventory.posted")
      ActivityLog.log_posted(posted, actor: admin)
      after_count = activity_count(posted.uuid, action: "warehouse.inventory.posted")

      assert after_count == before_count + 1
    end

    test "log_corrected/3 inserts a warehouse.inventory.corrected row", %{conn: _conn} do
      admin = create_admin_user()
      {:ok, doc} = Inventories.create_draft(%{created_by_uuid: admin.uuid, lines: []})
      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      before_count = activity_count(posted.uuid, action: "warehouse.inventory.corrected")
      ActivityLog.log_corrected(posted, %{note: %{from: "old", to: "new"}}, actor: admin)
      after_count = activity_count(posted.uuid, action: "warehouse.inventory.corrected")

      assert after_count == before_count + 1
    end

    test "log_reposted/2 inserts a warehouse.inventory.reposted row", %{conn: _conn} do
      admin = create_admin_user()
      {:ok, doc} = Inventories.create_draft(%{created_by_uuid: admin.uuid, lines: []})
      {:ok, posted} = Inventories.post_document(doc, admin.uuid)

      before_count = activity_count(posted.uuid, action: "warehouse.inventory.reposted")
      ActivityLog.log_reposted(posted, actor: admin)
      after_count = activity_count(posted.uuid, action: "warehouse.inventory.reposted")

      assert after_count == before_count + 1
    end

    test "activity rows carry the correct resource_uuid (document uuid)", %{conn: _conn} do
      admin = create_admin_user()
      {:ok, doc} = Inventories.create_draft(%{created_by_uuid: admin.uuid, lines: []})

      ActivityLog.log_created(doc, actor: admin)

      entry =
        PhoenixKitWarehouse.Test.Repo.one(
          from(e in Entry,
            where: e.resource_uuid == ^doc.uuid and e.action == "warehouse.inventory.created",
            limit: 1
          )
        )

      assert entry != nil
      assert entry.resource_uuid == doc.uuid
      assert entry.resource_type == "inventory_document"
      assert entry.module == "warehouse"
    end
  end
end
