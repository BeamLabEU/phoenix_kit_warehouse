defmodule PhoenixKitWarehouse.Web.DocumentTrashActionLiveTest do
  @moduledoc """
  "Move to trash" and the trash view in the lists and forms of goods receipts,
  goods issues, stocktakes and transfers (the same pieces internal and
  supplier orders have): the row menu item, its card copy, the Active / Trash
  tabs with Restore, the form button, the confirmation, and the server-side
  checks behind them.

  The shared rules run once per kind; what a transfer has on its own (a
  reason for each status) has its own tests below.
  """
  use PhoenixKitWarehouse.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Activity
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  alias PhoenixKitWarehouse.{
    GoodsIssue,
    GoodsIssues,
    GoodsReceipt,
    GoodsReceipts,
    Inventories,
    InventoryDocument,
    StockLedger,
    Transfer,
    Transfers
  }

  alias PhoenixKitWarehouse.Test.Repo

  alias PhoenixKitWarehouse.Web.{
    GoodsIssueFormLive,
    GoodsReceiptFormLive,
    InventoryFormLive,
    TransferFormLive
  }

  @location "00000000-0000-0000-0000-000000000001"
  @source_location "00000000-0000-0000-0000-0000000000a1"
  @destination_location "00000000-0000-0000-0000-0000000000a2"

  @posted_reason "A posted document cannot be deleted"
  @in_transit_reason "A transfer in transit cannot be deleted — cancel it first"
  @confirm "#pk-modal-cancel_trash button[phx-click=confirm_trash]"
  @cancel "#pk-modal-cancel_trash button[phx-click=cancel_trash]"

  setup do
    Repo.delete_all(GoodsReceipt)
    Repo.delete_all(GoodsIssue)
    Repo.delete_all(InventoryDocument)
    Repo.delete_all(Transfer)

    {:ok, admin: admin!()}
  end

  defp admin! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "doc-trash-#{System.unique_integer([:positive])}@example.com",
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

  # ---------------------------------------------------------------------------
  # The four kinds
  # ---------------------------------------------------------------------------

  defp draft!(kind, attrs \\ %{})

  defp draft!(:gr, attrs) do
    {:ok, doc} = GoodsReceipts.create_goods_receipt(Map.merge(%{location_uuid: @location}, attrs))
    doc
  end

  defp draft!(:gi, attrs) do
    {:ok, doc} = GoodsIssues.create_goods_issue(Map.merge(%{location_uuid: @location}, attrs))
    doc
  end

  defp draft!(:inv, attrs) do
    {:ok, doc} = Inventories.create_draft(Map.merge(%{location_uuid: @location}, attrs))
    doc
  end

  defp draft!(:tr, attrs) do
    base = %{
      source_location_uuid: @source_location,
      destination_location_uuid: @destination_location
    }

    {:ok, doc} = Transfers.create_transfer(Map.merge(base, attrs))
    doc
  end

  # A document that may not go to the trash: posted, or a transfer in transit.
  defp blocked!(:gr) do
    {:ok, posted} =
      GoodsReceipts.post_goods_receipt(draft!(:gr, %{lines: [line("received_quantity")]}), nil)

    posted
  end

  defp blocked!(:gi) do
    item = Ecto.UUID.generate()
    seed!(item, @location)
    draft = draft!(:gi, %{lines: [line(item, "issued_quantity")]})
    {:ok, posted} = GoodsIssues.post_goods_issue(draft, nil)
    posted
  end

  defp blocked!(:inv) do
    {:ok, posted} =
      Inventories.post_document(draft!(:inv, %{lines: [line("counted_quantity")]}), nil)

    posted
  end

  defp blocked!(:tr), do: in_transit!()

  defp in_transit! do
    item = Ecto.UUID.generate()
    seed!(item, @source_location)

    {:ok, shipped} =
      Transfers.ship_transfer(draft!(:tr, %{lines: [line(item, "transfer_quantity")]}), nil)

    shipped
  end

  defp blocked_reason(:tr), do: @in_transit_reason
  defp blocked_reason(_kind), do: @posted_reason

  defp trash!(:gr, doc, actor), do: ok!(GoodsReceipts.soft_delete(doc, actor.uuid))
  defp trash!(:gi, doc, actor), do: ok!(GoodsIssues.soft_delete(doc, actor.uuid))
  defp trash!(:inv, doc, actor), do: ok!(Inventories.soft_delete_document(doc, actor.uuid))
  defp trash!(:tr, doc, actor), do: ok!(Transfers.soft_delete_transfer(doc, actor.uuid))

  defp schema(:gr), do: GoodsReceipt
  defp schema(:gi), do: GoodsIssue
  defp schema(:inv), do: InventoryDocument
  defp schema(:tr), do: Transfer

  defp reload(kind, doc), do: Repo.get!(schema(kind), doc.uuid)

  # A blocked document that sits in the trash (legacy data; no function of the
  # module can make one, so the row is written directly).
  defp force_trash!(kind, doc, actor) do
    {1, _} =
      Repo.update_all(from(d in schema(kind), where: d.uuid == ^doc.uuid),
        set: [
          deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          deleted_by_uuid: actor.uuid
        ]
      )

    reload(kind, doc)
  end

  defp tag(:gr, doc), do: "#GR-#{doc.number}"
  defp tag(:gi, doc), do: "#GI-#{doc.number}"
  defp tag(:inv, doc), do: "Inventory ##{doc.number}"
  defp tag(:tr, doc), do: "#TR-#{doc.number}"

  defp index_path(:gr), do: Routes.path("/admin/warehouse/goods-receipts")
  defp index_path(:gi), do: Routes.path("/admin/warehouse/goods-issues")
  defp index_path(:inv), do: Routes.path("/admin/warehouse/inventories")
  defp index_path(:tr), do: Routes.path("/admin/warehouse/transfers")

  defp trash_path(kind), do: index_path(kind) <> "?view=trash"

  defp form_path(:inv, doc), do: Routes.path("/admin/warehouse/inventory/#{doc.uuid}")
  defp form_path(kind, doc), do: index_path(kind) <> "/#{doc.uuid}"

  # The id of a row's ⋮ menu in the table: stocktakes keep their old one.
  defp menu_id(:inv, doc), do: "doc-menu-#{doc.uuid}"
  defp menu_id(kind, doc), do: "#{kind}-menu-#{doc.uuid}"

  # The form assign that holds the document.
  defp doc_assign(:gr), do: :receipt
  defp doc_assign(:gi), do: :issue
  defp doc_assign(:inv), do: :doc
  defp doc_assign(:tr), do: :transfer

  defp line(quantity_key), do: line(Ecto.UUID.generate(), quantity_key)

  defp line(item_uuid, quantity_key) do
    %{"item_uuid" => item_uuid, "name" => "Material", "unit" => "pcs", quantity_key => "4"}
  end

  defp seed!(item_uuid, location) do
    {:ok, _} = StockLedger.upsert_quantity(item_uuid, Decimal.new("10"), location_uuid: location)
  end

  defp ok!({:ok, value}), do: value

  defp ids(html) do
    html |> LazyHTML.from_document() |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
  end

  defp duplicates(list), do: list |> Enum.frequencies() |> Enum.filter(fn {_, n} -> n > 1 end)

  for {kind, form_live} <- [
        gr: GoodsReceiptFormLive,
        gi: GoodsIssueFormLive,
        inv: InventoryFormLive,
        tr: TransferFormLive
      ] do
    @kind kind
    @p Atom.to_string(kind)
    @form_live form_live

    describe "#{@p} list: the tabs" do
      test "the Trash tab is hidden while the trash is empty", %{conn: conn} = ctx do
        draft!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        assert has_element?(lv, "##{@p}-tab-active")
        refute has_element?(lv, "##{@p}-tab-trash")
      end

      test "the Active view lists live documents, the trash view the trashed ones",
           %{conn: conn} = ctx do
        live_doc = draft!(@kind)
        trashed = trash!(@kind, draft!(@kind), ctx.admin)
        conn = log_in(conn, ctx.admin)

        {:ok, lv, _html} = live(conn, index_path(@kind))
        assert has_element?(lv, "##{@p}-row-#{live_doc.uuid}")
        refute has_element?(lv, "##{@p}-row-#{trashed.uuid}")
        assert has_element?(lv, "##{@p}-tab-trash", "(1)")
        refute has_element?(lv, "##{@p}-deleted-at-#{live_doc.uuid}")

        lv |> element("##{@p}-tab-trash") |> render_click()
        assert_patch(lv, trash_path(@kind))

        assert has_element?(lv, "##{@p}-row-#{trashed.uuid}")
        refute has_element?(lv, "##{@p}-row-#{live_doc.uuid}")

        assert has_element?(
                 lv,
                 "##{@p}-deleted-at-#{trashed.uuid}",
                 Calendar.strftime(trashed.deleted_at, "%d.%m.%Y")
               )

        assert has_element?(
                 lv,
                 "##{@p}-deleted-by-#{trashed.uuid}",
                 User.display_name(ctx.admin)
               )
      end

      test "the trash view counts a trashed posted document too and says when it is empty",
           %{conn: conn} = ctx do
        conn = log_in(conn, ctx.admin)
        {:ok, lv, _html} = live(conn, trash_path(@kind))
        assert has_element?(lv, "##{@p}-trash-empty")

        force_trash!(@kind, blocked!(@kind), ctx.admin)
        {:ok, lv, _html} = live(conn, index_path(@kind))
        assert has_element?(lv, "##{@p}-tab-trash", "(1)")
      end
    end

    describe "#{@p} list: restore" do
      test "a trashed draft is restored and leaves the trash", %{conn: conn} = ctx do
        trashed = trash!(@kind, draft!(@kind), ctx.admin)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), trash_path(@kind))

        lv |> element("##{@p}-restore-#{trashed.uuid}") |> render_click()

        assert has_element?(lv, "#flash-info", "Restored from the trash: #{tag(@kind, trashed)}.")
        refute has_element?(lv, "##{@p}-row-#{trashed.uuid}")
        assert reload(@kind, trashed).deleted_at == nil
      end

      test "a trashed blocked document has no Restore and a forged event changes nothing",
           %{conn: conn} = ctx do
        legacy = force_trash!(@kind, blocked!(@kind), ctx.admin)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), trash_path(@kind))

        assert has_element?(lv, "##{@p}-row-#{legacy.uuid}")
        refute has_element?(lv, "##{@p}-restore-#{legacy.uuid}")

        render_click(lv, "restore", %{"uuid" => legacy.uuid})

        assert has_element?(lv, "#flash-error", "Only drafts can be restored")
        assert reload(@kind, legacy).deleted_at != nil
      end

      test "a malformed uuid is a document not found", %{conn: conn} = ctx do
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), trash_path(@kind))

        render_click(lv, "restore", %{"uuid" => "not-a-uuid"})

        assert has_element?(lv, "#flash-error", "Document not found")
      end
    end

    describe "#{@p} list: the menu item" do
      test "a draft gets an active item, a blocked document a disabled one with the reason",
           %{conn: conn} = ctx do
        draft = draft!(@kind)
        blocked = blocked!(@kind)

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        assert has_element?(lv, "##{menu_id(@kind, draft)}")
        assert has_element?(lv, "##{@p}-trash-#{draft.uuid}[phx-click=request_trash]")
        refute has_element?(lv, "##{@p}-trash-#{draft.uuid}[disabled]")
        refute has_element?(lv, "##{@p}-trash-reason-#{draft.uuid}")

        assert has_element?(lv, "##{@p}-trash-#{blocked.uuid}[disabled]")
        refute has_element?(lv, "##{@p}-trash-#{blocked.uuid}[phx-click]")
        assert has_element?(lv, "##{@p}-trash-reason-#{blocked.uuid}", blocked_reason(@kind))
      end

      test "the trash view has Open, not Edit, and no Move to trash item", %{conn: conn} = ctx do
        trashed = trash!(@kind, draft!(@kind), ctx.admin)

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), trash_path(@kind))

        assert has_element?(lv, "##{menu_id(@kind, trashed)} a", "Open")
        refute has_element?(lv, "##{menu_id(@kind, trashed)} a", "Edit")
        refute has_element?(lv, "[id^=#{@p}-trash-#{trashed.uuid}]")
        refute has_element?(lv, "[phx-click=request_trash]")
      end
    end

    describe "#{@p} list: the confirmation" do
      test "the item opens the confirmation naming the document", %{conn: conn} = ctx do
        draft = draft!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        lv |> element("##{@p}-trash-#{draft.uuid}") |> render_click()

        assert has_element?(lv, "##{@p}-trash-confirm-doc", tag(@kind, draft))
        refute render(lv) =~ "Do you want to continue?"
        assert reload(@kind, draft).deleted_at == nil
      end

      test "confirming moves the draft to the trash as the current user", %{conn: conn} = ctx do
        draft = draft!(@kind)
        conn = log_in(conn, ctx.admin)
        {:ok, lv, _html} = live(conn, index_path(@kind))

        lv |> element("##{@p}-trash-#{draft.uuid}") |> render_click()
        lv |> element(@confirm) |> render_click()

        assert has_element?(lv, "#flash-info", "Moved to the trash: #{tag(@kind, draft)}.")
        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        refute has_element?(lv, "##{@p}-row-#{draft.uuid}")
        assert has_element?(lv, "##{@p}-tab-trash", "(1)")

        trashed = reload(@kind, draft)
        assert trashed.deleted_at != nil
        assert trashed.deleted_by_uuid == ctx.admin.uuid

        {:ok, lv, _html} = live(conn, trash_path(@kind))
        assert has_element?(lv, "##{@p}-row-#{draft.uuid}")
      end

      test "cancelling closes the confirmation and changes nothing", %{conn: conn} = ctx do
        draft = draft!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        lv |> element("##{@p}-trash-#{draft.uuid}") |> render_click()
        lv |> element(@cancel) |> render_click()

        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        assert has_element?(lv, "##{@p}-row-#{draft.uuid}")
        assert reload(@kind, draft).deleted_at == nil

        render_click(lv, "confirm_trash", %{})
        assert reload(@kind, draft).deleted_at == nil
      end

      test "a confirmation without a candidate does nothing", %{conn: conn} = ctx do
        draft = draft!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        render_click(lv, "confirm_trash", %{})

        refute has_element?(lv, "#flash-info")
        assert has_element?(lv, "##{@p}-row-#{draft.uuid}")
        assert reload(@kind, draft).deleted_at == nil
      end
    end

    describe "#{@p} list: the server checks the request" do
      test "a forged request for a blocked document gets the reason, no confirmation",
           %{conn: conn} = ctx do
        blocked = blocked!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        render_click(lv, "request_trash", %{"uuid" => blocked.uuid})

        assert has_element?(lv, "#flash-error", blocked_reason(@kind))
        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        assert reload(@kind, blocked).deleted_at == nil
        assert reload(@kind, blocked).status == blocked.status
      end

      test "a malformed or unknown uuid is a document not found", %{conn: conn} = ctx do
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        render_click(lv, "request_trash", %{"uuid" => "not-a-uuid"})
        assert has_element?(lv, "#flash-error", "Document not found")

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))
        render_click(lv, "request_trash", %{"uuid" => Ecto.UUID.generate()})
        assert has_element?(lv, "#flash-error", "Document not found")

        refute has_element?(lv, "##{@p}-trash-confirm-doc")
      end
    end

    describe "#{@p} list: the card view" do
      test "the cards carry the menu with Move to trash", %{conn: conn} = ctx do
        draft = draft!(@kind)
        blocked = blocked!(@kind)

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        assert has_element?(lv, "##{@p}-card-menu-#{draft.uuid}")
        assert has_element?(lv, "##{@p}-card-trash-#{draft.uuid}[phx-click=request_trash]")
        assert has_element?(lv, "##{@p}-card-trash-#{blocked.uuid}[disabled]")

        assert has_element?(
                 lv,
                 "##{@p}-card-trash-reason-#{blocked.uuid}",
                 blocked_reason(@kind)
               )

        lv |> element("##{@p}-card-trash-#{draft.uuid}") |> render_click()
        assert has_element?(lv, "##{@p}-trash-confirm-doc", tag(@kind, draft))
      end

      test "a trashed draft's card restores it", %{conn: conn} = ctx do
        trashed = trash!(@kind, draft!(@kind), ctx.admin)

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), trash_path(@kind))

        refute has_element?(lv, "[id^=#{@p}-card-trash-]")
        lv |> element("##{@p}-card-restore-#{trashed.uuid}") |> render_click()

        assert reload(@kind, trashed).deleted_at == nil
      end

      test "no id repeats on the page, active or trash", %{conn: conn} = ctx do
        draft!(@kind)
        blocked!(@kind)
        trash!(@kind, draft!(@kind), ctx.admin)
        conn = log_in(conn, ctx.admin)

        for path <- [index_path(@kind), trash_path(@kind)] do
          {:ok, lv, _html} = live(conn, path)
          assert lv |> render() |> ids() |> duplicates() == []
        end

        {:ok, lv, _html} = live(conn, index_path(@kind))
        lv |> element("[id^=#{@p}-trash-][phx-click=request_trash]") |> render_click()
        assert lv |> render() |> ids() |> duplicates() == []
      end
    end

    describe "#{@p} form: Move to trash" do
      test "a draft gets an active button, a blocked document a disabled one with a tooltip",
           %{conn: conn} = ctx do
        conn = log_in(conn, ctx.admin)

        {:ok, lv, _html} = live(conn, form_path(@kind, draft!(@kind)))
        assert has_element?(lv, "##{@p}-trash[phx-click=request_trash]")
        refute has_element?(lv, "##{@p}-trash[disabled]")

        {:ok, lv, _html} = live(conn, form_path(@kind, blocked!(@kind)))
        assert has_element?(lv, "##{@p}-trash[disabled]")
        refute has_element?(lv, "##{@p}-trash[phx-click]")
        assert has_element?(lv, ".tooltip[data-tip='#{blocked_reason(@kind)}'] ##{@p}-trash")
        assert has_element?(lv, "##{@p}-trash-reason", blocked_reason(@kind))
      end

      test "confirming draws the form as trashed, Restore brings it back", %{conn: conn} = ctx do
        draft = draft!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))

        lv |> element("##{@p}-trash") |> render_click()
        assert has_element?(lv, "##{@p}-trash-confirm-doc", tag(@kind, draft))
        assert render(lv) =~ "Unsaved changes in the form will not be saved."

        lv |> element(@confirm) |> render_click()

        assert has_element?(lv, "#flash-info", "Moved to the trash: #{tag(@kind, draft)}.")
        assert has_element?(lv, "##{@p}-trash-banner")
        assert has_element?(lv, "##{@p}-trash-banner", User.display_name(ctx.admin))
        assert has_element?(lv, "##{@p}-restore")
        refute has_element?(lv, "##{@p}-trash")
        refute has_element?(lv, "button[phx-click=save_draft]")
        assert reload(@kind, draft).deleted_by_uuid == ctx.admin.uuid

        lv |> element("##{@p}-restore") |> render_click()

        assert has_element?(lv, "#flash-info", "Restored from the trash: #{tag(@kind, draft)}.")
        assert reload(@kind, draft).deleted_at == nil
        refute has_element?(lv, "##{@p}-trash-banner")
        assert has_element?(lv, "##{@p}-trash[phx-click=request_trash]")
        assert has_element?(lv, "button[phx-click=save_draft]")
      end

      test "cancelling keeps the draft live", %{conn: conn} = ctx do
        draft = draft!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))

        lv |> element("##{@p}-trash") |> render_click()
        lv |> element(@cancel) |> render_click()

        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        refute has_element?(lv, "##{@p}-trash-banner")
        assert reload(@kind, draft).deleted_at == nil
      end

      test "a forged request on a blocked document gets the reason, no confirmation",
           %{conn: conn} = ctx do
        blocked = blocked!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, blocked))

        render_click(lv, "request_trash", %{})

        assert has_element?(lv, "#flash-error", blocked_reason(@kind))
        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        assert reload(@kind, blocked).deleted_at == nil
      end

      test "a confirmation without a candidate does nothing", %{conn: conn} = ctx do
        draft = draft!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))

        render_click(lv, "confirm_trash", %{})

        refute has_element?(lv, "#flash-info")
        refute has_element?(lv, "##{@p}-trash-banner")
        assert reload(@kind, draft).deleted_at == nil
      end

      test "a draft trashed in another tab is drawn as trashed", %{conn: conn} = ctx do
        draft = draft!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))
        trash!(@kind, draft, ctx.admin)

        lv |> element("##{@p}-trash") |> render_click()

        assert has_element?(lv, "#flash-error", "The document is already in the trash")
        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        assert has_element?(lv, "##{@p}-trash-banner")
      end

      test "requests without a document are refused, not a crash" do
        socket = %Phoenix.LiveView.Socket{
          assigns:
            Map.put(
              %{__changed__: %{}, flash: %{}, trash_candidate: nil, current_user: nil},
              doc_assign(@kind),
              nil
            )
        }

        for event <- ~w(request_trash restore) do
          assert {:noreply, socket} = @form_live.handle_event(event, %{}, socket)
          assert socket.assigns.flash["error"] == "Document not found"
          assert socket.assigns.trash_candidate == nil
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Transfers: a reason for each status
  # ---------------------------------------------------------------------------

  describe "transfer list: the reason of each status" do
    test "in transit, done and cancelled each get their own disabled item", %{conn: conn} = ctx do
      in_transit = in_transit!()
      {:ok, done} = Transfers.receive_transfer(in_transit!(), nil)
      {:ok, cancelled} = Transfers.cancel_transfer(draft!(:tr), nil)

      {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(:tr))

      for {doc, reason} <- [
            {in_transit, @in_transit_reason},
            {done, "A completed transfer cannot be deleted"},
            {cancelled, "A cancelled transfer cannot be deleted"}
          ] do
        assert has_element?(lv, "#tr-trash-#{doc.uuid}[disabled]")
        assert has_element?(lv, "#tr-trash-reason-#{doc.uuid}", reason)
        assert has_element?(lv, "#tr-card-trash-reason-#{doc.uuid}", reason)
      end
    end

    test "a forged request for a done transfer gets its reason", %{conn: conn} = ctx do
      {:ok, done} = Transfers.receive_transfer(in_transit!(), nil)
      {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(:tr))

      render_click(lv, "request_trash", %{"uuid" => done.uuid})

      assert has_element?(lv, "#flash-error", "A completed transfer cannot be deleted")
      assert reload(:tr, done).deleted_at == nil
    end
  end

  describe "transfer form: the reason of each status" do
    test "done and cancelled transfers get a disabled button with their reason",
         %{conn: conn} = ctx do
      conn = log_in(conn, ctx.admin)
      {:ok, done} = Transfers.receive_transfer(in_transit!(), nil)
      {:ok, cancelled} = Transfers.cancel_transfer(draft!(:tr), nil)

      for {doc, reason} <- [
            {done, "A completed transfer cannot be deleted"},
            {cancelled, "A cancelled transfer cannot be deleted"}
          ] do
        {:ok, lv, _html} = live(conn, form_path(:tr, doc))
        assert has_element?(lv, "#tr-trash[disabled]")
        assert has_element?(lv, "#tr-trash-reason", reason)
      end
    end
  end

  # The moves are logged with the user who made them (the context's job;
  # checked here once through the UI path of the four kinds' shared helper).
  test "the list's move to the trash and the restore are logged with the actor",
       %{conn: conn} = ctx do
    draft = draft!(:tr)
    conn = log_in(conn, ctx.admin)
    {:ok, lv, _html} = live(conn, index_path(:tr))

    lv |> element("#tr-trash-#{draft.uuid}") |> render_click()
    lv |> element(@confirm) |> render_click()

    {:ok, lv, _html} = live(conn, trash_path(:tr))
    lv |> element("#tr-restore-#{draft.uuid}") |> render_click()

    for verb <- ~w(trashed restored) do
      assert [entry] =
               Activity.list(action: "warehouse.transfer.#{verb}", resource_uuid: draft.uuid).entries

      assert entry.actor_uuid == ctx.admin.uuid
    end
  end
end
