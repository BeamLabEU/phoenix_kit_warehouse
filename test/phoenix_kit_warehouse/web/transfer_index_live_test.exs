defmodule PhoenixKitWarehouse.Web.TransferIndexLiveTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Test.Repo
  alias PhoenixKitWarehouse.Transfer
  alias PhoenixKitWarehouse.Transfers

  setup do
    Repo.delete_all(Transfer)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_email, do: "tr-index-#{System.unique_integer([:positive])}@example.com"

  defp create_admin_user do
    {:ok, user} =
      Auth.register_user(%{
        "email" => unique_email(),
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

  defp index_path, do: Routes.path("/admin/warehouse/transfers")

  defp create_transfer(attrs \\ %{}) do
    {:ok, transfer} = Transfers.create_transfer(attrs)
    transfer
  end

  # Creates real Location records tagged with a fresh warehouse LocationType and
  # marks that type as the warehouse type. The per-test sandbox rolls both the
  # rows and the setting back, so no manual cleanup is needed.
  defp setup_warehouses!(names) do
    {:ok, type} =
      Locations.create_location_type(%{
        name: "TR Index WH Type #{System.unique_integer([:positive])}"
      })

    locations =
      Enum.map(names, fn name ->
        {:ok, loc} = Locations.create_location(%{name: name, status: "active"})
        Locations.sync_location_types(loc.uuid, [type.uuid])
        loc
      end)

    StockLedger.set_warehouse_location_type_uuid(type.uuid)
    locations
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "transfer index" do
    test "renders the warehouse header with Transfers tab", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "Transfers"
    end

    test "shows a New transfer link pointing at the new-transfer route", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, lv, _html} = live(conn, index_path())

      new_path = Routes.path("/admin/warehouse/transfers/new")
      assert has_element?(lv, ~s(a[href="#{new_path}"]), "New transfer")
    end

    test "lists existing transfers", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_transfer()

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "#TR-#{transfer.number}"
    end

    test "shows empty state when no transfers", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "No transfers yet"
    end

    test "does not show soft-deleted transfers", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)
      transfer = create_transfer()
      {:ok, _} = Transfers.soft_delete_transfer(transfer, admin.uuid)

      {:ok, _lv, html} = live(conn, index_path())

      refute html =~ "#TR-#{transfer.number}"
    end

    test "resolves source/destination warehouse names via a batched lookup", %{conn: conn} do
      admin = create_admin_user()
      conn = log_in_admin(conn, admin)

      [source, destination] =
        setup_warehouses!(["TR Index Source", "TR Index Destination"])

      transfer =
        create_transfer(%{
          source_location_uuid: source.uuid,
          destination_location_uuid: destination.uuid
        })

      {:ok, _lv, html} = live(conn, index_path())

      assert html =~ "#TR-#{transfer.number}"
      assert html =~ "TR Index Source"
      assert html =~ "TR Index Destination"
    end
  end
end
