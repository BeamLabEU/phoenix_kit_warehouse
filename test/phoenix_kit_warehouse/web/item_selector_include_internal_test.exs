defmodule PhoenixKitWarehouse.Web.ItemSelectorIncludeInternalTest do
  @moduledoc """
  The warehouse always sees items of internal (hidden) catalogue categories:
  stock counts, internal orders and transfers deal in physical stock, and a
  fastener the picker silently skips is a line nobody can book.

  Catalogue 0.49+ hides the internal branch in `ItemSelectorModal` unless it
  gets `include_internal`. The catalogue this tree is locked to (0.48.1) has no
  such rule and drops the attr without a trace, so the modal's own state shows
  nothing there. These tests therefore trace the `ItemSelectorModal.update/2`
  call the LiveView makes when the picker opens and read the assigns it hands
  over. That holds on any catalogue version; deleting `include_internal={true}`
  from a form fails its test.
  """

  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Web.Components.ItemSelectorModal
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.Transfers

  @default_location_uuid "00000000-0000-0000-0000-000000000001"

  defp create_admin_user do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "sel-internal-#{System.unique_integer([:positive])}@example.com",
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

  # Opens the item selector at `path` and returns the assigns the LiveView
  # passes to `ItemSelectorModal.update/2` for the component with `component_id`.
  defp selector_update_assigns(conn, path, component_id) do
    {:ok, lv, _html} = live(conn, path)

    # A trace pattern on a module that is not loaded yet matches nothing.
    Code.ensure_loaded!(ItemSelectorModal)
    :erlang.trace_pattern({ItemSelectorModal, :update, 2}, true, [])
    :erlang.trace(lv.pid, true, [:call, tracer: self()])

    try do
      html = lv |> element("[phx-click='open_item_selector']") |> render_click()
      assert html =~ component_id
    after
      :erlang.trace(lv.pid, false, [:call])
      :erlang.trace_pattern({ItemSelectorModal, :update, 2}, false, [])
    end

    assert_receive {:trace, _, :call,
                    {ItemSelectorModal, :update, [%{id: ^component_id} = assigns, _socket]}}

    assigns
  end

  test "inventory form opens the item selector with include_internal", %{conn: conn} do
    conn = log_in_admin(conn, create_admin_user())
    {:ok, doc} = Inventories.create_draft(%{lines: []})

    path = Routes.path("/admin/warehouse/inventory/#{doc.uuid}/items")
    assigns = selector_update_assigns(conn, path, "inventory-item-selector")

    assert assigns[:include_internal] == true
  end

  test "internal order form opens the item selector with include_internal", %{conn: conn} do
    conn = log_in_admin(conn, create_admin_user())

    {:ok, order} =
      InternalOrders.create_internal_order(%{
        location_uuid: @default_location_uuid,
        lines: [],
        note: ""
      })

    path = Routes.path("/admin/warehouse/internal-orders/#{order.uuid}/items")

    assigns = selector_update_assigns(conn, path, "internal-order-item-selector")

    assert assigns[:include_internal] == true
  end

  test "transfer form opens the item selector with include_internal", %{conn: conn} do
    conn = log_in_admin(conn, create_admin_user())
    {:ok, transfer} = Transfers.create_transfer(%{})

    path = Routes.path("/admin/warehouse/transfers/#{transfer.uuid}/items")
    assigns = selector_update_assigns(conn, path, "transfer-item-selector")

    assert assigns[:include_internal] == true
  end
end
