defmodule PhoenixKitWarehouse.Web.SupplierOrderTrashLiveTest do
  @moduledoc """
  The trash of supplier orders in the admin UI: the "Active / Trash" tabs of
  the list, the restore buttons (with and without the `:one_draft_per_source`
  switch), the form of a trashed document, and the answer to a save or post of
  a document that went to the trash meanwhile.
  """
  use PhoenixKitWarehouse.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Test.Repo
  alias PhoenixKitWarehouse.Web.SupplierOrderFormLive

  @location "00000000-0000-0000-0000-000000000001"

  setup do
    Repo.delete_all(SupplierOrder)

    previous = Application.fetch_env(:phoenix_kit_warehouse, :one_draft_per_source)
    Application.delete_env(:phoenix_kit_warehouse, :one_draft_per_source)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit_warehouse, :one_draft_per_source, value)
        :error -> Application.delete_env(:phoenix_kit_warehouse, :one_draft_per_source)
      end
    end)

    {:ok, supplier} =
      Catalogue.create_supplier(%{
        name: "Trash Supplier #{System.unique_integer([:positive])}",
        status: "active"
      })

    {:ok, supplier: supplier}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp admin! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "so-trash-#{System.unique_integer([:positive])}@example.com",
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

  defp index_path, do: Routes.path("/admin/warehouse/supplier-orders")
  defp trash_path, do: index_path() <> "?view=trash"
  defp form_path(order), do: Routes.path("/admin/warehouse/supplier-orders/#{order.uuid}")

  defp enable!, do: Application.put_env(:phoenix_kit_warehouse, :one_draft_per_source, true)

  defp io_uuid! do
    {:ok, io} = InternalOrders.create_internal_order(%{location_uuid: @location})
    io.uuid
  end

  defp draft!(supplier, attrs \\ %{}) do
    {:ok, order} =
      SupplierOrders.create_supplier_order(
        Map.merge(%{location_uuid: @location, supplier_uuid: supplier.uuid}, attrs)
      )

    order
  end

  defp trashed_draft!(supplier, actor, attrs \\ %{}) do
    {:ok, trashed} =
      supplier |> draft!(attrs) |> SupplierOrders.soft_delete_supplier_order(actor.uuid)

    trashed
  end

  # A posted document that sits in the trash (legacy data; no function of the
  # module can make one, so the row is written directly).
  defp trashed_posted!(supplier, actor) do
    {:ok, posted} = supplier |> draft!() |> SupplierOrders.post_supplier_order(actor.uuid)

    {1, _} =
      Repo.update_all(from(o in SupplierOrder, where: o.uuid == ^posted.uuid),
        set: [
          deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          deleted_by_uuid: actor.uuid
        ]
      )

    SupplierOrders.get_supplier_order!(posted.uuid)
  end

  defp reload(order), do: SupplierOrders.get_supplier_order!(order.uuid)

  defp tag(order), do: "#SO-#{order.number}"

  # ---------------------------------------------------------------------------
  # List: the tabs
  # ---------------------------------------------------------------------------

  describe "list tabs" do
    test "the Trash tab is hidden while the trash is empty", %{conn: conn, supplier: supplier} do
      conn = log_in(conn, admin!())
      draft!(supplier)

      {:ok, lv, _html} = live(conn, index_path())

      assert has_element?(lv, "#so-tab-active")
      refute has_element?(lv, "#so-tab-trash")
    end

    test "the Trash tab counts what is in the trash, posted documents included",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed_draft!(supplier, admin)
      trashed_draft!(supplier, admin)
      trashed_posted!(supplier, admin)
      draft!(supplier)

      {:ok, lv, _html} = live(conn, index_path())

      assert has_element?(lv, "#so-tab-trash", "(3)")
    end

    test "clicking the tab shows the trash in the URL and lists the trashed documents",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      live_order = draft!(supplier)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, index_path())
      assert has_element?(lv, "#so-row-#{live_order.uuid}")
      refute has_element?(lv, "#so-row-#{trashed.uuid}")

      assert has_element?(lv, "#so-tab-active[aria-selected=true]")
      assert has_element?(lv, "#so-tab-trash[aria-selected=false]")

      lv |> element("#so-tab-trash") |> render_click()
      assert_patch(lv, trash_path())

      assert has_element?(lv, "#so-row-#{trashed.uuid}")
      refute has_element?(lv, "#so-row-#{live_order.uuid}")
      assert has_element?(lv, "#so-tab-active[aria-selected=false]")
      assert has_element?(lv, "#so-tab-trash[aria-selected=true]")

      lv |> element("#so-tab-active") |> render_click()
      assert_patch(lv, index_path())
      assert has_element?(lv, "#so-row-#{live_order.uuid}")
    end

    test "the Trash tab stays once the trash is emptied from inside it",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, trash_path())
      lv |> element("#so-restore-#{trashed.uuid}") |> render_click()

      assert has_element?(lv, "#so-tab-trash", "(0)")
      assert has_element?(lv, "#so-trash-empty")
    end

    test "the trash view shows the deletion date and who deleted the document",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, trash_path())

      date = Calendar.strftime(trashed.deleted_at, "%d.%m.%Y")
      assert has_element?(lv, "#so-deleted-at-#{trashed.uuid}", date)
      assert has_element?(lv, "#so-deleted-by-#{trashed.uuid}", User.display_name(admin))
    end

    test "the Active view has no deletion columns", %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      draft!(supplier)
      trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, index_path())

      refute has_element?(lv, "[id^=so-deleted-at-]")
      refute has_element?(lv, "[id^=so-deleted-by-]")
    end
  end

  # ---------------------------------------------------------------------------
  # List: restore
  # ---------------------------------------------------------------------------

  describe "restore from the list" do
    test "restores a trashed draft and the list refreshes", %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, trash_path())
      html = lv |> element("#so-restore-#{trashed.uuid}") |> render_click()

      assert reload(trashed).deleted_at == nil
      refute has_element?(lv, "#so-row-#{trashed.uuid}")
      assert html =~ tag(trashed)
    end

    test "a trashed posted document has no Restore button, and the event is refused",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      posted = trashed_posted!(supplier, admin)
      draft = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, trash_path())

      assert has_element?(lv, "#so-row-#{posted.uuid}")
      refute has_element?(lv, "#so-restore-#{posted.uuid}")
      assert has_element?(lv, "#so-restore-#{draft.uuid}")

      html = render_click(lv, "restore", %{"uuid" => posted.uuid})

      assert html =~ "Only drafts can be restored"
      assert reload(posted).deleted_at != nil
    end

    test "without the switch a restore leaves the live draft of the pair alone",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      io = io_uuid!()
      old = trashed_draft!(supplier, admin, %{internal_order_uuid: io})
      current = draft!(supplier, %{internal_order_uuid: io})

      {:ok, lv, _html} = live(conn, trash_path())
      lv |> element("#so-restore-#{old.uuid}") |> render_click()

      assert reload(old).deleted_at == nil
      assert reload(current).deleted_at == nil
    end

    test "with the switch the restore sends the live draft of the pair to the trash and names it",
         %{conn: conn, supplier: supplier} do
      enable!()
      admin = admin!()
      conn = log_in(conn, admin)
      io = io_uuid!()
      old = trashed_draft!(supplier, admin, %{internal_order_uuid: io})
      current = draft!(supplier, %{internal_order_uuid: io})
      other_supplier_draft = draft!(other_supplier!(), %{internal_order_uuid: io})

      {:ok, lv, _html} = live(conn, trash_path())
      html = lv |> element("#so-restore-#{old.uuid}") |> render_click()

      assert reload(old).deleted_at == nil
      assert reload(current).deleted_at != nil
      assert reload(current).deleted_by_uuid == admin.uuid
      assert reload(other_supplier_draft).deleted_at == nil
      assert html =~ "Moved to the trash: #{tag(current)}"
    end

    test "with the switch a combined draft is restored without a swap",
         %{conn: conn, supplier: supplier} do
      enable!()
      admin = admin!()
      conn = log_in(conn, admin)
      io = io_uuid!()
      other_io = io_uuid!()

      combined =
        trashed_draft!(supplier, admin, %{
          internal_order_uuid: io,
          source_refs: [
            %{"type" => "internal_order", "uuid" => io},
            %{"type" => "internal_order", "uuid" => other_io}
          ]
        })

      current = draft!(supplier, %{internal_order_uuid: io})

      {:ok, lv, _html} = live(conn, trash_path())
      lv |> element("#so-restore-#{combined.uuid}") |> render_click()

      assert reload(combined).deleted_at == nil
      assert reload(current).deleted_at == nil
    end
  end

  defp other_supplier! do
    {:ok, supplier} =
      Catalogue.create_supplier(%{
        name: "Other Supplier #{System.unique_integer([:positive])}",
        status: "active"
      })

    supplier
  end

  # ---------------------------------------------------------------------------
  # Form of a trashed document
  # ---------------------------------------------------------------------------

  describe "form of a trashed draft" do
    test "shows the banner with the date and the user, and a Restore button",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))

      assert has_element?(lv, "#so-trash-banner")
      assert has_element?(lv, "#so-trash-banner", User.display_name(admin))

      assert has_element?(
               lv,
               "#so-trash-banner",
               Calendar.strftime(trashed.deleted_at, "%d.%m.%Y")
             )

      assert has_element?(lv, "#so-restore")
    end

    test "hides editing, posting, links, correction, folder and receipt",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))

      refute has_element?(lv, "button[phx-click=save_draft]")
      refute has_element?(lv, "button[phx-click=post]")
      refute has_element?(lv, "#so-note-input")
      refute has_element?(lv, "form[phx-change=set_supplier]")
      refute has_element?(lv, "button[phx-click=open_link_picker]")
      refute has_element?(lv, "button[phx-click=remove_source_ref]")
      refute has_element?(lv, "button[phx-click=save_correction]")
      refute has_element?(lv, "button[phx-click=register_receipt]")
      refute has_element?(lv, "a[href$='/files']")

      {:ok, lv, _html} = live(conn, form_path(trashed) <> "/lines")

      refute has_element?(lv, "button[phx-click=open_source_picker]")
      refute has_element?(lv, "button[phx-click=add_reserve]")
    end

    test "the lines of a trashed draft are read-only", %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)

      line = %{
        "item_uuid" => Ecto.UUID.generate(),
        "name" => "Plank",
        "unit" => "piece",
        "required_quantity" => "3",
        "shortfall_quantity" => "3",
        "ordered_quantity" => "3"
      }

      trashed = trashed_draft!(supplier, admin, %{lines: [line]})

      {:ok, lv, _html} = live(conn, form_path(trashed) <> "/lines")

      assert has_element?(lv, "td", "Plank")
      refute has_element?(lv, "#so-qty-form-0")
    end

    test "the files tab does not look for or make a storage folder",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, html} = live(conn, form_path(trashed) <> "/files")

      refute html =~ "Loading files"
      refute render(lv) =~ "Loading files"
      assert render(lv) =~ "Files are not available"
      assert reload(trashed).storage_folder_uuid == nil
    end

    test "Restore brings the document back as an editable draft",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))
      html = lv |> element("#so-restore") |> render_click()

      assert reload(trashed).deleted_at == nil
      refute has_element?(lv, "#so-trash-banner")
      assert has_element?(lv, "button[phx-click=save_draft]")
      assert has_element?(lv, "button[phx-click=post]")
      assert html =~ "Restored from the trash"
    end

    test "Restore on the Files tab starts looking for the storage folder",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, form_path(trashed) <> "/files")
      assert render(lv) =~ "Files are not available"

      html = lv |> element("#so-restore") |> render_click()

      assert reload(trashed).deleted_at == nil
      assert html =~ "Loading files"
      refute html =~ "Files are not available"
    end

    test "a restore event without a document is refused, not a crash" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, order: nil, current_user: nil}
      }

      assert {:noreply, socket} =
               SupplierOrderFormLive.handle_event(
                 "restore",
                 %{},
                 socket
               )

      assert socket.assigns.flash["error"] =~ "not found"
    end

    test "Restore with the switch names the draft that went to the trash",
         %{conn: conn, supplier: supplier} do
      enable!()
      admin = admin!()
      conn = log_in(conn, admin)
      io = io_uuid!()
      old = trashed_draft!(supplier, admin, %{internal_order_uuid: io})
      current = draft!(supplier, %{internal_order_uuid: io})

      {:ok, lv, _html} = live(conn, form_path(old))
      html = lv |> element("#so-restore") |> render_click()

      assert reload(old).deleted_at == nil
      assert reload(current).deleted_at != nil
      assert html =~ tag(current)
    end
  end

  describe "form of a trashed posted document" do
    test "shows the banner without Restore, and no actions at all",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      posted = trashed_posted!(supplier, admin)

      {:ok, lv, _html} = live(conn, form_path(posted))

      assert has_element?(lv, "#so-trash-banner")
      refute has_element?(lv, "#so-restore")
      refute has_element?(lv, "button[phx-click=register_receipt]")
      refute has_element?(lv, "button[phx-click=save_correction]")
      refute has_element?(lv, "button[phx-click=open_link_picker]")
      refute has_element?(lv, "a[href$='/files']")
    end

    test "the events behind the hidden buttons are refused", %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      posted = trashed_posted!(supplier, admin)

      {:ok, lv, _html} = live(conn, form_path(posted))

      for event <- ~w(register_receipt save_correction) do
        assert render_click(lv, event, %{}) =~ "moved to the trash"
      end

      assert Repo.aggregate(PhoenixKitWarehouse.GoodsReceipt, :count) == 0
    end
  end

  describe "a live document keeps its form" do
    test "a draft has no banner and no Restore button", %{conn: conn, supplier: supplier} do
      conn = log_in(conn, admin!())
      order = draft!(supplier)

      {:ok, lv, _html} = live(conn, form_path(order))

      refute has_element?(lv, "#so-trash-banner")
      refute has_element?(lv, "#so-restore")
      assert has_element?(lv, "button[phx-click=save_draft]")
      assert has_element?(lv, "form[phx-change=set_supplier]")
      assert has_element?(lv, "a[href$='/files']")
    end
  end

  # ---------------------------------------------------------------------------
  # A document that went to the trash while the form was open
  # ---------------------------------------------------------------------------

  describe "save and post of a document that went to the trash meanwhile" do
    test "Save draft says so and redraws the form as a trashed document",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      order = draft!(supplier)

      {:ok, lv, _html} = live(conn, form_path(order))
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, admin.uuid)

      html = lv |> element("button[phx-click=save_draft]") |> render_click()

      assert html =~ "Document moved to the trash"
      assert has_element?(lv, "#so-trash-banner")
      refute has_element?(lv, "button[phx-click=save_draft]")
    end

    test "Post says so, does not post and redraws the form", %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      order = draft!(supplier)

      {:ok, lv, _html} = live(conn, form_path(order))
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, admin.uuid)

      html = lv |> element("button[phx-click=post]") |> render_click()

      assert html =~ "Document moved to the trash"
      assert has_element?(lv, "#so-trash-banner")
      assert reload(order).status == "draft"
    end

    test "choosing a supplier says so and changes nothing", %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      order = draft!(supplier)
      other = other_supplier!()

      {:ok, lv, _html} = live(conn, form_path(order))
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, admin.uuid)

      html =
        lv
        |> form("form[phx-change=set_supplier]", %{"supplier_uuid" => other.uuid})
        |> render_change()

      assert html =~ "Document moved to the trash"
      assert reload(order).supplier_uuid == supplier.uuid
    end

    test "Add 10% reserve says so and redraws the form as a trashed document",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      order = draft!(supplier)

      {:ok, lv, _html} = live(conn, form_path(order) <> "/lines")
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, admin.uuid)

      html = lv |> element("button[phx-click=add_reserve]") |> render_click()

      assert html =~ "Document moved to the trash"
      refute html =~ "Failed to apply reserve"
      assert has_element?(lv, "#so-trash-banner")
      refute has_element?(lv, "button[phx-click=add_reserve]")
    end

    test "Save draft draws the stored lines, not the unsaved buffer",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)

      line = %{
        "item_uuid" => Ecto.UUID.generate(),
        "name" => "Plank",
        "unit" => "piece",
        "required_quantity" => "3",
        "shortfall_quantity" => "3",
        "ordered_quantity" => "3"
      }

      order = draft!(supplier, %{lines: [line]})

      {:ok, lv, _html} = live(conn, form_path(order) <> "/lines")

      lv
      |> form("#so-qty-form-0", %{"ordered_quantity" => "47"})
      |> render_change()

      assert has_element?(lv, "#so-qty-0[value='47']")

      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, admin.uuid)
      lv |> element("button[phx-click=save_draft]") |> render_click()

      assert has_element?(lv, "#so-trash-banner")
      refute has_element?(lv, "span.tabular-nums", "47")
      assert has_element?(lv, "span.tabular-nums", "3")
    end

    test "importing from an internal order says so and redraws the form as a trashed document",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      order = draft!(supplier)
      {:ok, io} = InternalOrders.create_internal_order(%{location_uuid: @location})
      {:ok, io} = InternalOrders.post_internal_order(io, admin.uuid)

      {:ok, lv, _html} = live(conn, form_path(order) <> "/lines")

      lv |> element("button[phx-click='open_source_picker']") |> render_click()

      lv
      |> element("input[phx-click='source_picker_toggle'][phx-value-uuid='#{io.uuid}']")
      |> render_click()

      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, admin.uuid)

      html = lv |> element("button[phx-click='source_picker_confirm']") |> render_click()

      assert html =~ "Document moved to the trash"
      refute html =~ "Failed to import lines"
      assert has_element?(lv, "#so-trash-banner")
      refute has_element?(lv, "button[phx-click=source_picker_confirm]")
    end
  end

  # ---------------------------------------------------------------------------
  # Review follow-ups
  # ---------------------------------------------------------------------------

  describe "restore buttons" do
    test "the banner button and the row menu item wait for the answer",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))
      assert has_element?(lv, "#so-restore[phx-disable-with]")

      {:ok, lv, _html} = live(conn, trash_path())
      assert has_element?(lv, "#so-restore-#{trashed.uuid}[phx-disable-with]")
    end

    test "a restore event with a uuid that is not one is refused, not a crash",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, trash_path())

      html = render_click(lv, "restore", %{"uuid" => "not-a-uuid"})

      assert html =~ "Document not found"
      assert Process.alive?(lv.pid)
    end
  end

  describe "the Files tab of a document that went to the trash" do
    test "does not keep the upload browser of the folder it had",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      order = draft!(supplier)

      {:ok, lv, _html} = live(conn, form_path(order) <> "/files")
      send(lv.pid, {:files_folder_result, {:ok, %{uuid: Ecto.UUID.generate()}}})
      assert has_element?(lv, "#media-browser-so-#{order.uuid}")

      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, admin.uuid)
      render_click(lv, "save_draft", %{})

      assert has_element?(lv, "#so-trash-banner")
      refute has_element?(lv, "#media-browser-so-#{order.uuid}")
      assert render(lv) =~ "Files are not available"
    end

    test "ignores a folder that was found after the document went to the trash",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, form_path(trashed) <> "/files")
      send(lv.pid, {:files_folder_result, {:ok, %{uuid: Ecto.UUID.generate()}}})

      refute has_element?(lv, "#media-browser-so-#{trashed.uuid}")
      assert render(lv) =~ "Files are not available"
    end
  end

  describe "a document restored in another tab" do
    test "the form goes back to the live mode instead of refusing every event",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))
      assert has_element?(lv, "#so-trash-banner")

      {:ok, _} = SupplierOrders.restore_supplier_order(trashed, admin.uuid)

      html = render_click(lv, "save_draft", %{})

      refute html =~ "Document moved to the trash"
      refute has_element?(lv, "#so-trash-banner")
      assert has_element?(lv, "button[phx-click=save_draft]")
    end

    test "a document that is still in the trash keeps answering that it is",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      trashed = trashed_draft!(supplier, admin)

      {:ok, lv, _html} = live(conn, form_path(trashed))

      html = render_click(lv, "save_draft", %{})

      assert html =~ "Document moved to the trash"
      assert has_element?(lv, "#so-trash-banner")
    end
  end

  describe "links of a document that went to the trash meanwhile" do
    test "removing a link says so and redraws the form as a trashed document",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      io_uuid = io_uuid!()

      order =
        draft!(supplier, %{source_refs: [%{"type" => "internal_order", "uuid" => io_uuid}]})

      {:ok, lv, _html} = live(conn, form_path(order))
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, admin.uuid)

      html =
        render_click(lv, "remove_source_ref", %{"type" => "internal_order", "uuid" => io_uuid})

      assert html =~ "Document moved to the trash"
      refute html =~ "Failed to remove link"
      assert has_element?(lv, "#so-trash-banner")
      assert [%{"uuid" => ^io_uuid}] = reload(order).source_refs
    end

    test "adding a link says so and redraws the form as a trashed document",
         %{conn: conn, supplier: supplier} do
      admin = admin!()
      conn = log_in(conn, admin)
      {:ok, io} = InternalOrders.create_internal_order(%{location_uuid: @location})
      {:ok, io} = InternalOrders.post_internal_order(io, admin.uuid)
      order = draft!(supplier)

      {:ok, lv, _html} = live(conn, form_path(order))
      render_click(lv, "open_link_picker", %{})
      render_click(lv, "source_picker_toggle", %{"uuid" => io.uuid})
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(order, admin.uuid)

      html = render_click(lv, "source_picker_confirm", %{})

      assert html =~ "Document moved to the trash"
      refute html =~ "Failed to add link"
      assert has_element?(lv, "#so-trash-banner")
      assert reload(order).source_refs == []
    end
  end
end
