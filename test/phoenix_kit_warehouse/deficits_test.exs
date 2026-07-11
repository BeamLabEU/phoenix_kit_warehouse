defmodule PhoenixKitWarehouse.DeficitsTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.Deficits
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.MinStockSettings
  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.Test.MigrationsRunner
  alias PhoenixKitWarehouse.Test.Repo

  @location_uuid "00000000-0000-0000-0000-000000000001"

  # `phoenix_kit_warehouse_min_stock` is created by this package's OWN
  # versioned migration module (see `PhoenixKitWarehouse.Migrations.Postgres`
  # / T16), not by core PhoenixKit's `ensure_current/2` bootstrap that
  # `test_helper.exs` runs once at suite start. Bringing it up here — inside
  # each test's own sandboxed transaction, same trick as
  # `PhoenixKitWarehouse.MinStockSettingsTest` / `TransfersTest` — is
  # idempotent (`IF NOT EXISTS` DDL) and rolls back with everything else at
  # `on_exit`.
  setup do
    Ecto.Migrator.up(Repo, :os.system_time(:microsecond), MigrationsRunner, log: false)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp line(item_uuid, required_quantity) do
    %{
      "item_uuid" => item_uuid,
      "name" => "Item",
      "sku" => "SKU",
      "unit" => "pcs",
      "required_quantity" => required_quantity
    }
  end

  # `internal_orders.performed_by_uuid` has a real FK to `phoenix_kit_users`
  # — posting requires an actual user row, not an arbitrary UUID.
  defp user_uuid do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "deficits-test-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Deficits",
        "last_name" => "Test"
      })

    user.uuid
  end

  defp create_posted_io!(lines) do
    {:ok, order} =
      InternalOrders.create_internal_order(%{location_uuid: @location_uuid, lines: lines})

    {:ok, posted} = InternalOrders.post_internal_order(order, user_uuid())
    posted
  end

  defp create_draft_io!(lines) do
    {:ok, order} =
      InternalOrders.create_internal_order(%{location_uuid: @location_uuid, lines: lines})

    order
  end

  defp create_issue_against_io!(io_uuid, lines_breakdown) do
    {:ok, issue} =
      GoodsIssues.create_goods_issue(%{
        location_uuid: @location_uuid,
        lines: [],
        source_refs: [
          %{"type" => "internal_order", "uuid" => io_uuid, "lines" => lines_breakdown}
        ]
      })

    issue
  end

  # ---------------------------------------------------------------------------
  # reserved_by_item/0
  # ---------------------------------------------------------------------------

  describe "reserved_by_item/0" do
    test "a posted internal order with nothing issued yet reserves its full required_quantity" do
      item_uuid = Ecto.UUID.generate()
      create_posted_io!([line(item_uuid, "4")])

      reserved = Deficits.reserved_by_item()

      assert Decimal.equal?(reserved[item_uuid], Decimal.new("4"))
    end

    test "quantity already issued against the order reduces its reservation" do
      item_uuid = Ecto.UUID.generate()
      io = create_posted_io!([line(item_uuid, "4")])
      create_issue_against_io!(io.uuid, %{item_uuid => Decimal.new("1")})

      reserved = Deficits.reserved_by_item()

      assert Decimal.equal?(reserved[item_uuid], Decimal.new("3"))
    end

    test "draft internal orders reserve nothing" do
      item_uuid = Ecto.UUID.generate()
      create_draft_io!([line(item_uuid, "4")])

      reserved = Deficits.reserved_by_item()

      assert reserved[item_uuid] in [nil, Decimal.new("0")]
    end

    test "two posted internal orders on the same item are clamped and summed per order, not globally" do
      item_uuid = Ecto.UUID.generate()

      # IO A: required 2, nothing issued yet -> reserved 2.
      create_posted_io!([line(item_uuid, "2")])

      # IO B: required 1, over-issued to 3 -> clamps to 0, NOT -2. A naive
      # global `Σrequired - Σissued` (3 - 3 = 0) would wrongly cancel out IO
      # A's still-open reservation; per-order clamping keeps them
      # independent, so the correct total is 2 + 0 = 2.
      io_b = create_posted_io!([line(item_uuid, "1")])
      create_issue_against_io!(io_b.uuid, %{item_uuid => Decimal.new("3")})

      reserved = Deficits.reserved_by_item()

      assert Decimal.equal?(reserved[item_uuid], Decimal.new("2"))
    end
  end

  # ---------------------------------------------------------------------------
  # available_by_item/0
  # ---------------------------------------------------------------------------

  describe "available_by_item/0" do
    test "on-hand quantity minus reserved quantity" do
      item_uuid = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item_uuid, "10", location_uuid: @location_uuid)
      io = create_posted_io!([line(item_uuid, "4")])
      create_issue_against_io!(io.uuid, %{item_uuid => Decimal.new("1")})

      available = Deficits.available_by_item()

      assert Decimal.equal?(available[item_uuid], Decimal.new("7"))
    end

    test "an item with stock and only a draft (non-reserving) order is fully available" do
      item_uuid = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item_uuid, "10", location_uuid: @location_uuid)
      create_draft_io!([line(item_uuid, "4")])

      available = Deficits.available_by_item()

      assert Decimal.equal?(available[item_uuid], Decimal.new("10"))
    end

    test "an item reserved with no Stock row surfaces a negative available quantity" do
      item_uuid = Ecto.UUID.generate()
      create_posted_io!([line(item_uuid, "5")])

      available = Deficits.available_by_item()

      assert Decimal.equal?(available[item_uuid], Decimal.new("-5"))
    end
  end

  # ---------------------------------------------------------------------------
  # list_deficits/0
  # ---------------------------------------------------------------------------

  describe "list_deficits/0" do
    test "an item below its configured minimum is listed with the correct deficit" do
      item_uuid = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item_uuid, "10", location_uuid: @location_uuid)
      io = create_posted_io!([line(item_uuid, "4")])
      create_issue_against_io!(io.uuid, %{item_uuid => Decimal.new("1")})
      {:ok, _} = MinStockSettings.set_min_quantity(item_uuid, "8")

      [entry] = Enum.filter(Deficits.list_deficits(), &(&1.item_uuid == item_uuid))

      assert Decimal.equal?(entry.available, Decimal.new("7"))
      assert Decimal.equal?(entry.min_quantity, Decimal.new("8"))
      assert Decimal.equal?(entry.deficit, Decimal.new("1"))
    end

    test "an item at or above its minimum is omitted" do
      item_uuid = Ecto.UUID.generate()
      {:ok, _} = Warehouse.upsert_quantity(item_uuid, "10", location_uuid: @location_uuid)
      {:ok, _} = MinStockSettings.set_min_quantity(item_uuid, "10")

      refute Enum.any?(Deficits.list_deficits(), &(&1.item_uuid == item_uuid))
    end

    test "an item with no configured minimum is omitted no matter how low its availability is" do
      item_uuid = Ecto.UUID.generate()
      create_posted_io!([line(item_uuid, "5")])

      refute Enum.any?(Deficits.list_deficits(), &(&1.item_uuid == item_uuid))
    end
  end
end
