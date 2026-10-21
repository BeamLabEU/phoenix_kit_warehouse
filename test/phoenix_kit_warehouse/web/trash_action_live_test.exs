defmodule PhoenixKitWarehouse.Web.TrashActionLiveTest do
  @moduledoc """
  "Move to trash" in the lists and forms of internal and supplier orders: the
  row menu item (active for a draft, disabled with the reason otherwise), the
  same item in the card view, the form button, the confirmation, and the
  server-side checks behind them (a forged or stale event, a malformed uuid, a
  confirmation without a candidate).
  """
  use PhoenixKitWarehouse.LiveCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.{InternalOrder, InternalOrders, SupplierOrder, SupplierOrders}
  alias PhoenixKitWarehouse.Test.Repo
  alias PhoenixKitWarehouse.Web.{InternalOrderFormLive, SupplierOrderFormLive}

  @location "00000000-0000-0000-0000-000000000001"
  @posted_reason "A posted document cannot be deleted"
  @confirm "#pk-modal-cancel_trash button[phx-click=confirm_trash]"
  @cancel "#pk-modal-cancel_trash button[phx-click=cancel_trash]"

  setup do
    Repo.delete_all(SupplierOrder)
    Repo.delete_all(InternalOrder)

    {:ok, supplier} =
      Catalogue.create_supplier(%{
        name: "Trash Action Supplier #{System.unique_integer([:positive])}",
        status: "active"
      })

    admin = admin!()

    {:ok, supplier: supplier, admin: admin}
  end

  defp admin! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "trash-action-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Trash",
        "last_name" => "Action"
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
  # The two kinds
  # ---------------------------------------------------------------------------

  defp draft!(:io, _ctx) do
    {:ok, order} = InternalOrders.create_internal_order(%{location_uuid: @location})
    order
  end

  defp draft!(:so, ctx) do
    {:ok, order} =
      SupplierOrders.create_supplier_order(%{
        location_uuid: @location,
        supplier_uuid: ctx.supplier.uuid
      })

    order
  end

  defp post!(:io, order, actor) do
    {:ok, posted} = InternalOrders.post_internal_order(order, actor.uuid)
    posted
  end

  defp post!(:so, order, actor) do
    {:ok, posted} = SupplierOrders.post_supplier_order(order, actor.uuid)
    posted
  end

  defp posted!(kind, ctx), do: post!(kind, draft!(kind, ctx), ctx.admin)

  defp trash!(:io, order, actor) do
    {:ok, trashed} = InternalOrders.soft_delete_internal_order(order, actor.uuid)
    trashed
  end

  defp trash!(:so, order, actor) do
    {:ok, trashed} = SupplierOrders.soft_delete_supplier_order(order, actor.uuid)
    trashed
  end

  defp reload(:io, order), do: InternalOrders.get_internal_order!(order.uuid)
  defp reload(:so, order), do: SupplierOrders.get_supplier_order!(order.uuid)

  defp tag(:io, order), do: "#IO-#{order.number}"
  defp tag(:so, order), do: "#SO-#{order.number}"

  defp index_path(:io), do: Routes.path("/admin/warehouse/internal-orders")
  defp index_path(:so), do: Routes.path("/admin/warehouse/supplier-orders")
  defp trash_path(kind), do: index_path(kind) <> "?view=trash"
  defp form_path(kind, order), do: index_path(kind) <> "/#{order.uuid}"

  defp ids(html) do
    html |> LazyHTML.from_document() |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
  end

  defp duplicates(list), do: list |> Enum.frequencies() |> Enum.filter(fn {_, n} -> n > 1 end)

  for {kind, form_live} <- [io: InternalOrderFormLive, so: SupplierOrderFormLive] do
    @kind kind
    @p Atom.to_string(kind)
    @form_live form_live

    describe "#{@p} list: the menu item" do
      test "a draft gets an active item, a posted document a disabled one with the reason",
           %{conn: conn} = ctx do
        draft = draft!(@kind, ctx)
        posted = posted!(@kind, ctx)

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        assert has_element?(lv, "##{@p}-trash-#{draft.uuid}[phx-click=request_trash]")
        refute has_element?(lv, "##{@p}-trash-#{draft.uuid}[disabled]")
        refute has_element?(lv, "##{@p}-trash-reason-#{draft.uuid}")

        assert has_element?(lv, "##{@p}-trash-#{posted.uuid}[disabled]")
        refute has_element?(lv, "##{@p}-trash-#{posted.uuid}[phx-click]")
        assert has_element?(lv, "##{@p}-trash-reason-#{posted.uuid}", @posted_reason)
      end

      test "the trash view has no Move to trash item", %{conn: conn} = ctx do
        trashed = trash!(@kind, draft!(@kind, ctx), ctx.admin)

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), trash_path(@kind))

        assert has_element?(lv, "##{@p}-restore-#{trashed.uuid}")
        refute has_element?(lv, "[id^=#{@p}-trash-#{trashed.uuid}]")
        refute has_element?(lv, "[phx-click=request_trash]")
      end
    end

    describe "#{@p} list: the confirmation" do
      test "the item opens the confirmation naming the document", %{conn: conn} = ctx do
        draft = draft!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        lv |> element("##{@p}-trash-#{draft.uuid}") |> render_click()

        assert has_element?(lv, "##{@p}-trash-confirm-doc", tag(@kind, draft))
        refute render(lv) =~ "Do you want to continue?"
        assert reload(@kind, draft).deleted_at == nil
      end

      test "confirming moves the draft to the trash as the current user", %{conn: conn} = ctx do
        draft = draft!(@kind, ctx)
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
        draft = draft!(@kind, ctx)
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
        draft = draft!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        render_click(lv, "confirm_trash", %{})

        refute has_element?(lv, "#flash-info")
        assert has_element?(lv, "##{@p}-row-#{draft.uuid}")
        assert reload(@kind, draft).deleted_at == nil
      end

      test "a second confirmation of the same document is a no-op", %{conn: conn} = ctx do
        draft = draft!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        lv |> element("##{@p}-trash-#{draft.uuid}") |> render_click()
        lv |> element(@confirm) |> render_click()
        render_click(lv, "confirm_trash", %{})

        refute has_element?(lv, "#flash-error")
        assert reload(@kind, draft).deleted_at != nil
      end
    end

    describe "#{@p} list: the server checks the request" do
      test "a forged request for a posted document gets the reason, no confirmation",
           %{conn: conn} = ctx do
        posted = posted!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        render_click(lv, "request_trash", %{"uuid" => posted.uuid})

        assert has_element?(lv, "#flash-error", @posted_reason)
        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        assert reload(@kind, posted).deleted_at == nil
        assert reload(@kind, posted).status == "posted"
      end

      test "a draft posted in another tab is refused and its row redrawn", %{conn: conn} = ctx do
        draft = draft!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))
        post!(@kind, draft, ctx.admin)

        lv |> element("##{@p}-trash-#{draft.uuid}") |> render_click()

        assert has_element?(lv, "#flash-error", @posted_reason)
        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        assert has_element?(lv, "##{@p}-trash-#{draft.uuid}[disabled]")
      end

      test "a draft posted between the request and the confirmation stays out of the trash",
           %{conn: conn} = ctx do
        draft = draft!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        lv |> element("##{@p}-trash-#{draft.uuid}") |> render_click()
        post!(@kind, draft, ctx.admin)
        lv |> element(@confirm) |> render_click()

        assert has_element?(lv, "#flash-error", @posted_reason)
        assert reload(@kind, draft).deleted_at == nil
      end

      test "a draft trashed in another tab says it is already in the trash",
           %{conn: conn} = ctx do
        draft = draft!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))
        trash!(@kind, draft, ctx.admin)

        lv |> element("##{@p}-trash-#{draft.uuid}") |> render_click()

        assert has_element?(lv, "#flash-error", "The document is already in the trash")
        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        refute has_element?(lv, "##{@p}-row-#{draft.uuid}")
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
        draft = draft!(@kind, ctx)
        posted = posted!(@kind, ctx)

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(@kind))

        assert has_element?(lv, "##{@p}-card-menu-#{draft.uuid}")
        assert has_element?(lv, "##{@p}-card-trash-#{draft.uuid}[phx-click=request_trash]")
        assert has_element?(lv, "##{@p}-card-trash-#{posted.uuid}[disabled]")
        assert has_element?(lv, "##{@p}-card-trash-reason-#{posted.uuid}", @posted_reason)

        lv |> element("##{@p}-card-trash-#{draft.uuid}") |> render_click()
        assert has_element?(lv, "##{@p}-trash-confirm-doc", tag(@kind, draft))
      end

      test "a trashed draft's card restores it", %{conn: conn} = ctx do
        trashed = trash!(@kind, draft!(@kind, ctx), ctx.admin)

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), trash_path(@kind))

        refute has_element?(lv, "[id^=#{@p}-card-trash-]")
        lv |> element("##{@p}-card-restore-#{trashed.uuid}") |> render_click()

        assert reload(@kind, trashed).deleted_at == nil
      end

      test "no id repeats on the page, active or trash", %{conn: conn} = ctx do
        draft!(@kind, ctx)
        posted!(@kind, ctx)
        trash!(@kind, draft!(@kind, ctx), ctx.admin)
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

    describe "#{@p} form" do
      test "a draft gets an active button, a posted document a disabled one with a tooltip",
           %{conn: conn} = ctx do
        conn = log_in(conn, ctx.admin)

        {:ok, lv, _html} = live(conn, form_path(@kind, draft!(@kind, ctx)))
        assert has_element?(lv, "##{@p}-trash[phx-click=request_trash]")
        refute has_element?(lv, "##{@p}-trash[disabled]")

        {:ok, lv, _html} = live(conn, form_path(@kind, posted!(@kind, ctx)))
        assert has_element?(lv, "##{@p}-trash[disabled]")
        refute has_element?(lv, "##{@p}-trash[phx-click]")
        assert has_element?(lv, ".tooltip[data-tip='#{@posted_reason}'] ##{@p}-trash")
        assert has_element?(lv, "##{@p}-trash-reason", @posted_reason)
      end

      test "confirming draws the form as trashed, Restore brings it back", %{conn: conn} = ctx do
        draft = draft!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))

        lv |> element("##{@p}-trash") |> render_click()
        assert has_element?(lv, "##{@p}-trash-confirm-doc", tag(@kind, draft))
        assert render(lv) =~ "Unsaved changes in the form will not be saved."

        lv |> element(@confirm) |> render_click()

        assert has_element?(lv, "#flash-info", "Moved to the trash: #{tag(@kind, draft)}.")
        assert has_element?(lv, "##{@p}-trash-banner")
        assert has_element?(lv, "##{@p}-restore")
        refute has_element?(lv, "##{@p}-trash")
        refute has_element?(lv, "button[phx-click=save_draft]")
        assert reload(@kind, draft).deleted_by_uuid == ctx.admin.uuid

        lv |> element("##{@p}-restore") |> render_click()

        assert has_element?(lv, "#flash-info", "Restored from the trash: #{tag(@kind, draft)}.")
        assert reload(@kind, draft).deleted_at == nil
        assert has_element?(lv, "##{@p}-trash[phx-click=request_trash]")
      end

      test "cancelling keeps the draft live", %{conn: conn} = ctx do
        draft = draft!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))

        lv |> element("##{@p}-trash") |> render_click()
        lv |> element(@cancel) |> render_click()

        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        refute has_element?(lv, "##{@p}-trash-banner")
        assert reload(@kind, draft).deleted_at == nil
      end

      test "a forged request on a posted document gets the reason, no confirmation",
           %{conn: conn} = ctx do
        posted = posted!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, posted))

        render_click(lv, "request_trash", %{})

        assert has_element?(lv, "#flash-error", @posted_reason)
        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        assert reload(@kind, posted).deleted_at == nil
      end

      test "a confirmation without a candidate does nothing", %{conn: conn} = ctx do
        draft = draft!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))

        render_click(lv, "confirm_trash", %{})

        refute has_element?(lv, "#flash-info")
        refute has_element?(lv, "##{@p}-trash-banner")
        assert reload(@kind, draft).deleted_at == nil
      end

      test "a draft trashed in another tab is drawn as trashed", %{conn: conn} = ctx do
        draft = draft!(@kind, ctx)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))
        trash!(@kind, draft, ctx.admin)

        lv |> element("##{@p}-trash") |> render_click()

        assert has_element?(lv, "#flash-error", "The document is already in the trash")
        refute has_element?(lv, "##{@p}-trash-confirm-doc")
        assert has_element?(lv, "##{@p}-trash-banner")
      end

      test "a request without a document is refused, not a crash" do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}, flash: %{}, order: nil, trash_candidate: nil}
        }

        assert {:noreply, socket} = @form_live.handle_event("request_trash", %{}, socket)
        assert socket.assigns.flash["error"] == "Document not found"
        assert socket.assigns.trash_candidate == nil
      end

      test "a trashed draft has no Move to trash button", %{conn: conn} = ctx do
        trashed = trash!(@kind, draft!(@kind, ctx), ctx.admin)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, trashed))

        assert has_element?(lv, "##{@p}-trash-banner")
        refute has_element?(lv, "##{@p}-trash")
      end
    end
  end

  # The move to the trash is logged with the user who did it (the context's
  # job; checked here once through the UI path).
  test "the list's move to the trash is logged with the actor", %{conn: conn} = ctx do
    draft = draft!(:io, ctx)
    {:ok, lv, _html} = live(log_in(conn, ctx.admin), index_path(:io))

    lv |> element("#io-trash-#{draft.uuid}") |> render_click()
    lv |> element(@confirm) |> render_click()

    assert [entry] =
             Activity.list(action: "warehouse.internal_order.trashed", resource_uuid: draft.uuid).entries

    assert entry.actor_uuid == ctx.admin.uuid
    assert entry.metadata["trash_reason"] == "manual"
  end
end
