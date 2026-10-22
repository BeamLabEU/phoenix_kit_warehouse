defmodule PhoenixKitWarehouse.Web.InternalOrderTrashLiveTest do
  @moduledoc """
  The trash of internal orders in the admin UI: the "Active / Trash" tabs of
  the list, the restore buttons, the form of a trashed document, the answer to
  a save or conduct of a document that went to the trash meanwhile, and the
  `:one_draft_per_source` switch on the generation of supplier orders.
  """
  use PhoenixKitWarehouse.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Test.Fixtures
  alias PhoenixKitWarehouse.Test.Repo
  alias PhoenixKitWarehouse.Web.InternalOrderFormLive

  @location "00000000-0000-0000-0000-000000000001"

  setup do
    Repo.delete_all(InternalOrder)

    previous = Application.fetch_env(:phoenix_kit_warehouse, :one_draft_per_source)
    Application.delete_env(:phoenix_kit_warehouse, :one_draft_per_source)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit_warehouse, :one_draft_per_source, value)
        :error -> Application.delete_env(:phoenix_kit_warehouse, :one_draft_per_source)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp admin! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "io-trash-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Trash",
        "last_name" => "Keeper"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.promote_to_admin(user)
    Auth.get_user!(user.uuid)
  end

  defp log_in(conn, user) do
    token = Auth.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  defp index_path, do: Routes.path("/admin/warehouse/internal-orders")
  defp trash_path, do: index_path() <> "?view=trash"
  defp form_path(order), do: Routes.path("/admin/warehouse/internal-orders/#{order.uuid}")

  defp enable!, do: Application.put_env(:phoenix_kit_warehouse, :one_draft_per_source, true)

  defp draft!(attrs \\ %{}) do
    {:ok, order} =
      InternalOrders.create_internal_order(Map.merge(%{location_uuid: @location}, attrs))

    order
  end

  defp trashed_draft!(actor) do
    {:ok, trashed} = InternalOrders.soft_delete_internal_order(draft!(), actor.uuid)
    trashed
  end

  # A posted document that sits in the trash (legacy data; no function of the
  # module can make one, so the row is written directly).
  defp trashed_posted!(actor) do
    {:ok, posted} = InternalOrders.post_internal_order(draft!(), actor.uuid)

    {1, _} =
      Repo.update_all(from(o in InternalOrder, where: o.uuid == ^posted.uuid),
        set: [
          deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          deleted_by_uuid: actor.uuid
        ]
      )

    InternalOrders.get_internal_order!(posted.uuid)
  end

  defp reload(order), do: InternalOrders.get_internal_order!(order.uuid)

  defp tag(order), do: "#IO-#{order.number}"

  # ---------------------------------------------------------------------------
  # List: the tabs
  # ---------------------------------------------------------------------------

  describe "list tabs" do
    test "the Trash tab is hidden while the trash is empty", %{conn: conn} do
      conn = log_in(conn, admin!())
      draft!()

      {:ok, lv, _html} = live(conn, index_path())

      assert has_element?(lv, "#io-tab-active")
      refute has_element?(lv, "#io-tab-trash")
    end

    test "the Trash tab counts what is in the trash, posted documents included", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed_draft!(admin)
      trashed_draft!(admin)
      trashed_posted!(admin)
      draft!()

      {:ok, lv, _html} = live(conn, index_path())

      assert has_element?(lv, "#io-tab-trash", "(3)")
    end

    test "the Active view lists live documents only", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      live_order = draft!()
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, index_path())

      assert has_element?(lv, "#io-row-#{live_order.uuid}")
      refute has_element?(lv, "#io-row-#{trashed.uuid}")
    end

    test "clicking the tab shows the trash in the URL and lists the trashed documents",
         %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      live_order = draft!()
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, index_path())

      assert has_element?(lv, "#io-tab-active[aria-selected=true]")
      assert has_element?(lv, "#io-tab-trash[aria-selected=false]")

      lv |> element("#io-tab-trash") |> render_click()
      assert_patch(lv, trash_path())

      assert has_element?(lv, "#io-row-#{trashed.uuid}")
      refute has_element?(lv, "#io-row-#{live_order.uuid}")
      assert has_element?(lv, "#io-tab-active[aria-selected=false]")
      assert has_element?(lv, "#io-tab-trash[aria-selected=true]")

      lv |> element("#io-tab-active") |> render_click()
      assert_patch(lv, index_path())
      assert has_element?(lv, "#io-row-#{live_order.uuid}")
    end

    test "?view=trash opens the trash, and the tab stays when the trash is emptied",
         %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, trash_path())
      assert has_element?(lv, "#io-row-#{trashed.uuid}")

      lv |> element("#io-restore-#{trashed.uuid}") |> render_click()

      assert has_element?(lv, "#io-tab-trash", "(0)")
      assert has_element?(lv, "#io-trash-empty")
    end

    test "an unknown view falls back to the active list", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      live_order = draft!()
      trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, index_path() <> "?view=bogus")

      assert has_element?(lv, "#io-row-#{live_order.uuid}")
    end

    test "the trash view shows the deletion date and who deleted the document", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, trash_path())

      date = Calendar.strftime(trashed.deleted_at, "%d.%m.%Y")
      assert has_element?(lv, "#io-deleted-at-#{trashed.uuid}", date)
      assert has_element?(lv, "#io-deleted-by-#{trashed.uuid}", User.display_name(admin))
    end

    test "the Active view has no deletion columns", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      draft!()
      trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, index_path())

      refute has_element?(lv, "[id^=io-deleted-at-]")
      refute has_element?(lv, "[id^=io-deleted-by-]")
    end
  end

  # ---------------------------------------------------------------------------
  # List: restore
  # ---------------------------------------------------------------------------

  describe "restore from the list" do
    test "restores a trashed draft and the list refreshes", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, trash_path())

      html = lv |> element("#io-restore-#{trashed.uuid}") |> render_click()

      assert reload(trashed).deleted_at == nil
      refute has_element?(lv, "#io-row-#{trashed.uuid}")
      assert html =~ tag(trashed)

      {:ok, lv, _html} = live(conn, index_path())
      assert has_element?(lv, "#io-row-#{trashed.uuid}")
    end

    test "a trashed posted document has no Restore button", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      posted = trashed_posted!(admin)
      draft = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, trash_path())

      assert has_element?(lv, "#io-row-#{posted.uuid}")
      refute has_element?(lv, "#io-restore-#{posted.uuid}")
      assert has_element?(lv, "#io-restore-#{draft.uuid}")
    end

    test "an event for a posted trashed document is refused and changes nothing", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      posted = trashed_posted!(admin)

      {:ok, lv, _html} = live(conn, trash_path())

      html = render_click(lv, "restore", %{"uuid" => posted.uuid})

      assert html =~ "Only drafts can be restored"
      assert reload(posted).deleted_at != nil
    end

    test "without the switch a restore leaves the live drafts of the source alone",
         %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      source = %{"type" => "sub_order", "uuid" => Ecto.UUID.generate()}

      {:ok, %{order: old}} =
        InternalOrders.replace_draft_for_source([], source, created_by_uuid: admin.uuid)

      {:ok, %{order: current, superseded: [_]}} =
        InternalOrders.replace_draft_for_source([], source, created_by_uuid: admin.uuid)

      {:ok, lv, _html} = live(conn, trash_path())
      lv |> element("#io-restore-#{old.uuid}") |> render_click()

      assert reload(old).deleted_at == nil
      assert reload(current).deleted_at == nil
    end

    test "with the switch the restore sends the live drafts of the source to the trash and names them",
         %{conn: conn} do
      enable!()
      admin = admin!()
      conn = log_in(conn, admin)
      source = %{"type" => "sub_order", "uuid" => Ecto.UUID.generate()}

      {:ok, %{order: old}} =
        InternalOrders.replace_draft_for_source([], source, created_by_uuid: admin.uuid)

      {:ok, %{order: current, superseded: [_]}} =
        InternalOrders.replace_draft_for_source([], source, created_by_uuid: admin.uuid)

      {:ok, lv, _html} = live(conn, trash_path())
      html = lv |> element("#io-restore-#{old.uuid}") |> render_click()

      assert reload(old).deleted_at == nil
      assert reload(current).deleted_at != nil
      assert reload(current).deleted_by_uuid == admin.uuid
      assert html =~ tag(current)
    end

    test "with the switch a combined draft is restored without a swap", %{conn: conn} do
      enable!()
      admin = admin!()
      conn = log_in(conn, admin)
      source_a = %{"type" => "sub_order", "uuid" => Ecto.UUID.generate()}
      source_b = %{"type" => "sub_order", "uuid" => Ecto.UUID.generate()}

      combined = draft!(%{source_refs: [source_a, source_b]})
      {:ok, _} = InternalOrders.soft_delete_internal_order(combined, admin.uuid)

      {:ok, %{order: single}} =
        InternalOrders.replace_draft_for_source([], source_a, created_by_uuid: admin.uuid)

      {:ok, lv, _html} = live(conn, trash_path())
      lv |> element("#io-restore-#{combined.uuid}") |> render_click()

      assert reload(combined).deleted_at == nil
      assert reload(single).deleted_at == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Form of a trashed document
  # ---------------------------------------------------------------------------

  describe "form of a trashed draft" do
    test "shows the banner with the date and the user, and a Restore button", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))

      assert has_element?(lv, "#io-trash-banner")
      assert has_element?(lv, "#io-trash-banner", User.display_name(admin))

      assert has_element?(
               lv,
               "#io-trash-banner",
               Calendar.strftime(trashed.deleted_at, "%d.%m.%Y")
             )

      assert has_element?(lv, "#io-restore")
    end

    test "hides editing, conducting, links, correction, folder and the order buttons",
         %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))

      refute has_element?(lv, "button[phx-click=save_draft]")
      refute has_element?(lv, "button[phx-click=conduct]")
      refute has_element?(lv, "#io-note-input")
      refute has_element?(lv, "button[phx-click=open_link_picker]")
      refute has_element?(lv, "button[phx-click=remove_source_ref]")
      refute has_element?(lv, "button[phx-click=save_correction]")
      refute has_element?(lv, "button[phx-click=generate_supplier_orders]")
      refute has_element?(lv, "button[phx-click=issue_to_production]")
      refute has_element?(lv, "a[href$='/files']")

      {:ok, lv, _html} = live(conn, form_path(trashed) <> "/items")

      refute has_element?(lv, "button[phx-click=open_source_picker]")
      refute has_element?(lv, "button[phx-click=open_item_selector]")
    end

    test "the lines of a trashed draft are read-only", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)

      line = %{
        "item_uuid" => Ecto.UUID.generate(),
        "name" => "Plank",
        "unit" => "piece",
        "required_quantity" => "3"
      }

      {:ok, trashed} =
        InternalOrders.soft_delete_internal_order(draft!(%{lines: [line]}), admin.uuid)

      {:ok, lv, _html} = live(conn, form_path(trashed) <> "/items")

      assert has_element?(lv, "td", "Plank")
      refute has_element?(lv, "#io-qty-form-0")
      refute has_element?(lv, "button[phx-click=remove_line]")
    end

    test "the files tab does not look for or make a storage folder", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, html} = live(conn, form_path(trashed) <> "/files")

      refute html =~ "Loading files"
      refute render(lv) =~ "Loading files"
      assert render(lv) =~ "Files are not available"
    end

    test "Restore brings the document back as an editable draft", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))

      html = lv |> element("#io-restore") |> render_click()

      assert reload(trashed).deleted_at == nil
      refute has_element?(lv, "#io-trash-banner")
      assert has_element?(lv, "button[phx-click=save_draft]")
      assert has_element?(lv, "button[phx-click=conduct]")
      assert html =~ "Restored from the trash"
    end

    test "Restore on the Files tab starts looking for the storage folder", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, form_path(trashed) <> "/files")
      assert render(lv) =~ "Files are not available"

      html = lv |> element("#io-restore") |> render_click()

      assert reload(trashed).deleted_at == nil
      assert html =~ "Loading files"
      refute html =~ "Files are not available"
    end

    test "a restore event without a document is refused, not a crash" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, order: nil, current_user: nil}
      }

      assert {:noreply, socket} =
               InternalOrderFormLive.handle_event(
                 "restore",
                 %{},
                 socket
               )

      assert socket.assigns.flash["error"] =~ "not found"
    end

    test "Restore with the switch names the drafts that went to the trash", %{conn: conn} do
      enable!()
      admin = admin!()
      conn = log_in(conn, admin)
      source = %{"type" => "sub_order", "uuid" => Ecto.UUID.generate()}

      {:ok, %{order: old}} =
        InternalOrders.replace_draft_for_source([], source, created_by_uuid: admin.uuid)

      {:ok, %{order: current}} =
        InternalOrders.replace_draft_for_source([], source, created_by_uuid: admin.uuid)

      {:ok, lv, _html} = live(conn, form_path(old))
      html = lv |> element("#io-restore") |> render_click()

      assert reload(old).deleted_at == nil
      assert reload(current).deleted_at != nil
      assert html =~ tag(current)
    end
  end

  describe "form of a trashed posted document" do
    test "shows the banner without Restore, and no actions at all", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      posted = trashed_posted!(admin)

      {:ok, lv, _html} = live(conn, form_path(posted))

      assert has_element?(lv, "#io-trash-banner")
      refute has_element?(lv, "#io-restore")
      refute has_element?(lv, "button[phx-click=generate_supplier_orders]")
      refute has_element?(lv, "button[phx-click=issue_to_production]")
      refute has_element?(lv, "button[phx-click=save_correction]")
      refute has_element?(lv, "button[phx-click=open_link_picker]")
      refute has_element?(lv, "a[href$='/files']")
    end

    test "the events behind the hidden buttons are refused", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      posted = trashed_posted!(admin)

      {:ok, lv, _html} = live(conn, form_path(posted))

      for event <- ~w(generate_supplier_orders issue_to_production save_correction) do
        assert render_click(lv, event, %{}) =~ "moved to the trash"
      end

      assert SupplierOrders.list_supplier_orders()
             |> Enum.filter(&(&1.internal_order_uuid == posted.uuid)) == []
    end
  end

  describe "a live document keeps its form" do
    test "a draft has no banner and no Restore button", %{conn: conn} do
      conn = log_in(conn, admin!())
      order = draft!()

      {:ok, lv, _html} = live(conn, form_path(order))

      refute has_element?(lv, "#io-trash-banner")
      refute has_element?(lv, "#io-restore")
      assert has_element?(lv, "button[phx-click=save_draft]")
      assert has_element?(lv, "a[href$='/files']")
    end
  end

  # ---------------------------------------------------------------------------
  # A document that went to the trash while the form was open
  # ---------------------------------------------------------------------------

  describe "save and conduct of a document that went to the trash meanwhile" do
    test "Save draft says so and redraws the form as a trashed document", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      order = draft!()

      {:ok, lv, _html} = live(conn, form_path(order))
      {:ok, _} = InternalOrders.soft_delete_internal_order(order, admin.uuid)

      html = lv |> element("button[phx-click=save_draft]") |> render_click()

      assert html =~ "Document moved to the trash"
      assert has_element?(lv, "#io-trash-banner")
      refute has_element?(lv, "button[phx-click=save_draft]")
    end

    test "Conduct says so, does not post and redraws the form", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      order = draft!()

      {:ok, lv, _html} = live(conn, form_path(order))
      {:ok, _} = InternalOrders.soft_delete_internal_order(order, admin.uuid)

      html = lv |> element("button[phx-click=conduct]") |> render_click()

      assert html =~ "Document moved to the trash"
      assert has_element?(lv, "#io-trash-banner")
      assert reload(order).status == "draft"
    end

    test "Save draft draws the stored lines, not the unsaved buffer", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)

      line = %{
        "item_uuid" => Ecto.UUID.generate(),
        "name" => "Plank",
        "unit" => "piece",
        "required_quantity" => "3"
      }

      order = draft!(%{lines: [line]})

      {:ok, lv, _html} = live(conn, form_path(order) <> "/items")
      assert has_element?(lv, "td", "Plank")

      lv |> element("button[phx-click=remove_line]") |> render_click()
      refute has_element?(lv, "td", "Plank")

      {:ok, _} = InternalOrders.soft_delete_internal_order(order, admin.uuid)
      lv |> element("button[phx-click=save_draft]") |> render_click()

      assert has_element?(lv, "#io-trash-banner")
      assert has_element?(lv, "td", "Plank")
    end

    test "importing from a source says so and redraws the form as a trashed document",
         %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      order = draft!()
      source = Fixtures.insert_order!()

      {:ok, lv, _html} = live(conn, form_path(order) <> "/items")

      lv |> element("button[phx-click='open_source_picker']") |> render_click()

      lv
      |> element("input[phx-click='source_picker_toggle'][phx-value-uuid='#{source.uuid}']")
      |> render_click()

      {:ok, _} = InternalOrders.soft_delete_internal_order(order, admin.uuid)

      html = lv |> element("button[phx-click='source_picker_confirm']") |> render_click()

      assert html =~ "Document moved to the trash"
      refute html =~ "Failed to import lines"
      assert has_element?(lv, "#io-trash-banner")
      refute has_element?(lv, "button[phx-click=source_picker_confirm]")
    end
  end

  # ---------------------------------------------------------------------------
  # Generation of supplier orders and the switch
  # ---------------------------------------------------------------------------

  defp supplier_with_item! do
    n = System.unique_integer([:positive])
    {:ok, supplier} = Catalogue.create_supplier(%{name: "Supplier #{n}", status: "active"})
    {:ok, mfr} = Catalogue.create_manufacturer(%{name: "Mfr #{n}", status: "active"})
    Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Cat #{n}", status: "active"})

    {:ok, item} =
      Catalogue.create_item(%{
        name: "Item #{n}",
        catalogue_uuid: catalogue.uuid,
        manufacturer_uuid: mfr.uuid,
        status: "active"
      })

    %{supplier: supplier, item: item}
  end

  defp posted_io_with_item! do
    %{item: item, supplier: supplier} = supplier_with_item!()

    {:ok, io} =
      InternalOrders.create_internal_order(%{
        location_uuid: @location,
        lines: [
          %{
            "item_uuid" => item.uuid,
            "name" => item.name,
            "sku" => item.sku || "",
            "unit" => item.unit || "piece",
            "catalogue_uuid" => item.catalogue_uuid,
            "category_uuid" => item.category_uuid,
            "required_quantity" => "10"
          }
        ]
      })

    {:ok, posted} = InternalOrders.post_internal_order(io, nil)
    %{io: posted, supplier: supplier}
  end

  defp old_supplier_draft!(io, supplier) do
    {:ok, so} =
      SupplierOrders.create_supplier_order(%{
        location_uuid: @location,
        internal_order_uuid: io.uuid,
        supplier_uuid: supplier.uuid
      })

    so
  end

  defp so_reload(so), do: SupplierOrders.get_supplier_order!(so.uuid)

  defp so_tag(so), do: "#SO-#{so.number}"

  # The button opens the preview window (no browser confirmation); a
  # generation appends to the live draft of the pair and trashes nothing, with
  # the switch or without it. The window itself is covered in
  # InternalOrderGenerationPreviewLiveTest.
  defp open_preview!(lv) do
    lv |> element("#io-generate-supplier-orders") |> render_click()
    assert has_element?(lv, "#io-generation-preview")
    lv
  end

  defp generate!(lv, conn) do
    {:ok, _lv, html} =
      lv |> element("#io-generation-preview-form") |> render_submit() |> follow_redirect(conn)

    html
  end

  describe "generating supplier orders" do
    test "without the switch: no browser confirmation, the window names the draft it appends to",
         %{conn: conn} do
      conn = log_in(conn, admin!())
      %{io: io, supplier: supplier} = posted_io_with_item!()
      old = old_supplier_draft!(io, supplier)

      {:ok, lv, _html} = live(conn, form_path(io))

      refute has_element?(lv, "#io-generate-supplier-orders[data-confirm]")

      open_preview!(lv)

      assert has_element?(
               lv,
               "#io-preview-group-#{supplier.uuid}-target",
               "There is already a draft #{so_tag(old)}"
             )

      html = generate!(lv, conn)

      assert html =~ "Appended to: #{so_tag(old)}."
      refute html =~ "Moved to the trash"
      assert so_reload(old).deleted_at == nil
      assert [%{"item_uuid" => _}] = so_reload(old).lines

      assert from(o in SupplierOrder, where: o.internal_order_uuid == ^io.uuid)
             |> Repo.aggregate(:count) == 1
    end

    test "with the switch and a live draft: no browser confirmation, the window names it",
         %{conn: conn} do
      enable!()
      conn = log_in(conn, admin!())
      %{io: io, supplier: supplier} = posted_io_with_item!()
      old = old_supplier_draft!(io, supplier)

      {:ok, lv, _html} = live(conn, form_path(io))

      refute has_element?(lv, "#io-generate-supplier-orders[data-confirm]")
      open_preview!(lv)

      assert has_element?(lv, "#io-preview-group-#{supplier.uuid}-target", so_tag(old))
    end

    test "with the switch and no drafts: the window shows a new order", %{conn: conn} do
      enable!()
      conn = log_in(conn, admin!())
      %{io: io, supplier: supplier} = posted_io_with_item!()

      {:ok, lv, _html} = live(conn, form_path(io))
      open_preview!(lv)

      assert has_element?(lv, "#io-preview-group-#{supplier.uuid}-new")
      refute has_element?(lv, "#io-preview-group-#{supplier.uuid}-target")
    end

    test "with the switch the window appends to the combined draft, never a posted or a trashed one",
         %{conn: conn} do
      enable!()
      admin = admin!()
      conn = log_in(conn, admin)
      %{io: io, supplier: supplier} = posted_io_with_item!()

      {:ok, posted} =
        io |> old_supplier_draft!(supplier) |> SupplierOrders.post_supplier_order(admin.uuid)

      combined =
        io
        |> old_supplier_draft!(supplier)
        |> Ecto.Changeset.change(
          source_refs: [
            %{"type" => "internal_order", "uuid" => io.uuid},
            %{"type" => "internal_order", "uuid" => Ecto.UUID.generate()}
          ]
        )
        |> Repo.update!()

      {:ok, trashed} =
        io
        |> old_supplier_draft!(supplier)
        |> SupplierOrders.soft_delete_supplier_order(admin.uuid)

      {:ok, lv, _html} = live(conn, form_path(io))
      open_preview!(lv)

      target = "#io-preview-group-#{supplier.uuid}-target"
      assert has_element?(lv, target, so_tag(combined))
      refute has_element?(lv, target, so_tag(posted))
      refute has_element?(lv, target, so_tag(trashed))
    end

    test "with the switch the generation appends to the old draft, nothing is trashed",
         %{conn: conn} do
      enable!()
      admin = admin!()
      conn = log_in(conn, admin)
      %{io: io, supplier: supplier} = posted_io_with_item!()
      old = old_supplier_draft!(io, supplier)

      {:ok, lv, _html} = live(conn, form_path(io))
      html = lv |> open_preview!() |> generate!(conn)

      refute html =~ "Moved to the trash"

      appended = so_reload(old)
      assert appended.deleted_at == nil
      assert [%{"item_uuid" => _}] = appended.lines

      live =
        from(o in SupplierOrder,
          where: o.internal_order_uuid == ^io.uuid and is_nil(o.deleted_at)
        )
        |> Repo.all()

      assert length(live) == 1
    end

    test "with the switch a posted draft of the same supplier is not touched", %{conn: conn} do
      enable!()
      admin = admin!()
      conn = log_in(conn, admin)
      %{io: io, supplier: supplier} = posted_io_with_item!()

      {:ok, posted} =
        io |> old_supplier_draft!(supplier) |> SupplierOrders.post_supplier_order(admin.uuid)

      {:ok, lv, _html} = live(conn, form_path(io))
      html = lv |> open_preview!() |> generate!(conn)

      assert html =~ "Supplier orders created: 1."
      assert so_reload(posted).deleted_at == nil
      assert so_reload(posted).status == "posted"
    end
  end

  # ---------------------------------------------------------------------------
  # Review follow-ups
  # ---------------------------------------------------------------------------

  describe "restore buttons" do
    test "the banner button and the row menu item wait for the answer", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))
      assert has_element?(lv, "#io-restore[phx-disable-with]")

      {:ok, lv, _html} = live(conn, trash_path())
      assert has_element?(lv, "#io-restore-#{trashed.uuid}[phx-disable-with]")
    end

    test "a restore event with a uuid that is not one is refused, not a crash", %{conn: conn} do
      conn = log_in(conn, admin!())
      trashed_draft!(admin!())

      {:ok, lv, _html} = live(conn, trash_path())

      html = render_click(lv, "restore", %{"uuid" => "not-a-uuid"})

      assert html =~ "Document not found"
      assert Process.alive?(lv.pid)
    end
  end

  describe "the Files tab of a document that went to the trash" do
    test "does not keep the upload browser of the folder it had", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      order = draft!()

      {:ok, lv, _html} = live(conn, form_path(order) <> "/files")
      send(lv.pid, {:files_folder_result, {:ok, %{uuid: Ecto.UUID.generate()}}})
      assert has_element?(lv, "#media-browser-io-#{order.uuid}")

      {:ok, _} = InternalOrders.soft_delete_internal_order(order, admin.uuid)
      render_click(lv, "save_draft", %{})

      assert has_element?(lv, "#io-trash-banner")
      refute has_element?(lv, "#media-browser-io-#{order.uuid}")
      assert render(lv) =~ "Files are not available"
    end

    test "ignores a folder that was found after the document went to the trash",
         %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, form_path(trashed) <> "/files")
      send(lv.pid, {:files_folder_result, {:ok, %{uuid: Ecto.UUID.generate()}}})

      refute has_element?(lv, "#media-browser-io-#{trashed.uuid}")
      assert render(lv) =~ "Files are not available"
    end
  end

  describe "a document restored in another tab" do
    test "the form goes back to the live mode instead of refusing every event",
         %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))
      assert has_element?(lv, "#io-trash-banner")

      {:ok, _} = InternalOrders.restore_internal_order(trashed, admin.uuid)

      html = render_click(lv, "save_draft", %{})

      refute html =~ "Document moved to the trash"
      refute has_element?(lv, "#io-trash-banner")
      assert has_element?(lv, "button[phx-click=save_draft]")
    end

    test "a document that is still in the trash keeps answering that it is", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))

      html = render_click(lv, "save_draft", %{})

      assert html =~ "Document moved to the trash"
      assert has_element?(lv, "#io-trash-banner")
    end
  end

  describe "links of a document that went to the trash meanwhile" do
    test "removing a link says so and redraws the form as a trashed document",
         %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      source = Fixtures.insert_order!()
      order = draft!(%{source_refs: [%{"type" => "order", "uuid" => source.uuid}]})

      {:ok, lv, _html} = live(conn, form_path(order))
      {:ok, _} = InternalOrders.soft_delete_internal_order(order, admin.uuid)

      html = render_click(lv, "remove_source_ref", %{"type" => "order", "uuid" => source.uuid})

      assert html =~ "Document moved to the trash"
      refute html =~ "Failed to remove link"
      assert has_element?(lv, "#io-trash-banner")
      assert [%{"uuid" => uuid}] = reload(order).source_refs
      assert uuid == source.uuid
    end

    test "adding a link says so and redraws the form as a trashed document", %{conn: conn} do
      admin = admin!()
      conn = log_in(conn, admin)
      source = Fixtures.insert_order!()
      order = draft!()

      {:ok, lv, _html} = live(conn, form_path(order))
      render_click(lv, "open_link_picker", %{})
      render_click(lv, "source_picker_toggle", %{"uuid" => source.uuid})
      {:ok, _} = InternalOrders.soft_delete_internal_order(order, admin.uuid)

      html = render_click(lv, "source_picker_confirm", %{})

      assert html =~ "Document moved to the trash"
      refute html =~ "Failed to add link"
      assert has_element?(lv, "#io-trash-banner")
      assert reload(order).source_refs == []
    end
  end
end
