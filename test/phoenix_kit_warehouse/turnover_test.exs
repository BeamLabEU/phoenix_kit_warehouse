defmodule PhoenixKitWarehouse.TurnoverTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.Transfers
  alias PhoenixKitWarehouse.Turnover

  @location_uuid "00000000-0000-0000-0000-000000000001"
  @other_location_uuid "00000000-0000-0000-0000-000000000002"

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp today, do: Date.utc_today()

  defp user_uuid do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "turnover-test-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Turnover",
        "last_name" => "Test"
      })

    user.uuid
  end

  defp create_catalogue! do
    {:ok, cat} =
      Catalogue.create_catalogue(%{
        name: "Test Catalogue #{System.unique_integer([:positive])}",
        status: "active"
      })

    cat
  end

  defp create_item!(opts \\ []) do
    catalogue = create_catalogue!()

    {:ok, item} =
      Catalogue.create_item(%{
        name: Keyword.get(opts, :name, "Item #{System.unique_integer([:positive])}"),
        sku: Keyword.get(opts, :sku, "SKU-#{System.unique_integer([:positive])}"),
        unit: Keyword.get(opts, :unit, "piece"),
        catalogue_uuid: catalogue.uuid,
        status: "active"
      })

    item
  end

  defp receipt_line(item_uuid, qty),
    do: %{"item_uuid" => item_uuid, "received_quantity" => Decimal.new(qty)}

  defp issue_line(item_uuid, qty),
    do: %{"item_uuid" => item_uuid, "issued_quantity" => Decimal.new(qty)}

  defp transfer_line(item_uuid, qty),
    do: %{"item_uuid" => item_uuid, "transfer_quantity" => Decimal.new(qty)}

  defp inventory_line(item_uuid, qty),
    do: %{"item_uuid" => item_uuid, "counted_quantity" => Decimal.new(qty)}

  defp post_receipt!(item_uuid, qty, location_uuid, actor) do
    {:ok, receipt} =
      GoodsReceipts.create_goods_receipt(%{
        location_uuid: location_uuid,
        lines: [receipt_line(item_uuid, qty)]
      })

    {:ok, posted} = GoodsReceipts.post_goods_receipt(receipt, actor)
    posted
  end

  defp post_issue!(item_uuid, qty, location_uuid, actor) do
    {:ok, issue} =
      GoodsIssues.create_goods_issue(%{
        location_uuid: location_uuid,
        lines: [issue_line(item_uuid, qty)]
      })

    {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)
    posted
  end

  defp post_inventory_count!(item_uuid, qty, location_uuid, actor) do
    {:ok, doc} =
      Inventories.create_draft(%{
        location_uuid: location_uuid,
        lines: [inventory_line(item_uuid, qty)]
      })

    {:ok, posted} = Inventories.post_document(doc, actor)
    posted
  end

  defp ship_transfer!(item_uuid, qty, source_uuid, destination_uuid, actor) do
    {:ok, transfer} =
      Transfers.create_transfer(%{
        source_location_uuid: source_uuid,
        destination_location_uuid: destination_uuid,
        lines: [transfer_line(item_uuid, qty)]
      })

    {:ok, shipped} = Transfers.ship_transfer(transfer, actor)
    shipped
  end

  defp entry_for(results, item_uuid), do: Enum.find(results, &(&1.item_uuid == item_uuid))

  # ---------------------------------------------------------------------------
  # compute/3 — the plan's worked example
  # ---------------------------------------------------------------------------

  describe "compute/3 — combining sources" do
    test "receipt inflow, issue outflow, and a negative inventory correction combine" do
      actor = user_uuid()
      item = create_item!()

      post_receipt!(item.uuid, "10", @location_uuid, actor)
      post_issue!(item.uuid, "3", @location_uuid, actor)
      # Stock is now 10 - 3 = 7; counting 6 registers a -1 correction, so
      # outflow gains abs(-1) = 1 on top of the issue's 3.
      post_inventory_count!(item.uuid, "6", @location_uuid, actor)

      entry = Turnover.compute(nil, today(), today()) |> entry_for(item.uuid)

      assert Decimal.equal?(entry.inflow, Decimal.new("10"))
      assert Decimal.equal?(entry.outflow, Decimal.new("4"))
      assert Decimal.equal?(entry.balance, Decimal.new("6"))
    end

    test "a positive inventory correction adds to inflow, not outflow" do
      actor = user_uuid()
      item = create_item!()
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "5", location_uuid: @location_uuid)

      post_inventory_count!(item.uuid, "8", @location_uuid, actor)

      entry = Turnover.compute(nil, today(), today()) |> entry_for(item.uuid)

      assert Decimal.equal?(entry.inflow, Decimal.new("3"))
      assert Decimal.equal?(entry.outflow, Decimal.new("0"))
    end
  end

  # ---------------------------------------------------------------------------
  # Enrichment
  # ---------------------------------------------------------------------------

  describe "compute/3 — enrichment" do
    test "enriches each row with the item's current name, sku, and unit" do
      actor = user_uuid()
      item = create_item!(name: "Steel Bolt", sku: "BOLT-1", unit: "set")

      post_receipt!(item.uuid, "5", @location_uuid, actor)

      entry = Turnover.compute(nil, today(), today()) |> entry_for(item.uuid)

      assert entry.name == "Steel Bolt"
      assert entry.sku == "BOLT-1"
      assert entry.unit == "set"
    end
  end

  # ---------------------------------------------------------------------------
  # Filtering — date window, draft status, no-movement items
  # ---------------------------------------------------------------------------

  describe "compute/3 — filtering" do
    test "movements outside the date window are excluded" do
      actor = user_uuid()
      item = create_item!()
      post_receipt!(item.uuid, "10", @location_uuid, actor)

      yesterday = Date.add(today(), -1)

      refute Turnover.compute(nil, yesterday, yesterday) |> entry_for(item.uuid)
    end

    test "a draft goods receipt contributes nothing" do
      item = create_item!()

      {:ok, _draft} =
        GoodsReceipts.create_goods_receipt(%{
          location_uuid: @location_uuid,
          lines: [receipt_line(item.uuid, "10")]
        })

      refute Turnover.compute(nil, today(), today()) |> entry_for(item.uuid)
    end

    test "an item with current stock but no posted movement in the window is omitted" do
      item = create_item!()
      {:ok, _stock} = Warehouse.upsert_quantity(item.uuid, "50", location_uuid: @location_uuid)

      refute Turnover.compute(nil, today(), today()) |> entry_for(item.uuid)
    end
  end

  # ---------------------------------------------------------------------------
  # Warehouse scoping
  # ---------------------------------------------------------------------------

  describe "compute/3 — warehouse scoping" do
    test "location_uuid scopes receipts to that warehouse; nil sums every warehouse" do
      actor = user_uuid()
      item = create_item!()
      post_receipt!(item.uuid, "10", @location_uuid, actor)

      at_location = Turnover.compute(@location_uuid, today(), today()) |> entry_for(item.uuid)
      at_other = Turnover.compute(@other_location_uuid, today(), today()) |> entry_for(item.uuid)
      at_all = Turnover.compute(nil, today(), today()) |> entry_for(item.uuid)

      assert Decimal.equal?(at_location.inflow, Decimal.new("10"))
      assert at_other == nil
      assert Decimal.equal?(at_all.inflow, Decimal.new("10"))
    end

    test "balance is scoped to the given warehouse, not summed across all" do
      actor = user_uuid()
      item = create_item!()
      post_receipt!(item.uuid, "10", @location_uuid, actor)
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "99", location_uuid: @other_location_uuid)

      at_location = Turnover.compute(@location_uuid, today(), today()) |> entry_for(item.uuid)
      at_all = Turnover.compute(nil, today(), today()) |> entry_for(item.uuid)

      assert Decimal.equal?(at_location.balance, Decimal.new("10"))
      assert Decimal.equal?(at_all.balance, Decimal.new("109"))
    end
  end

  # ---------------------------------------------------------------------------
  # Transfers
  # ---------------------------------------------------------------------------

  describe "compute/3 — transfers" do
    test "shipping counts as outflow at the source only" do
      actor = user_uuid()
      item = create_item!()
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "10", location_uuid: @location_uuid)

      ship_transfer!(item.uuid, "4", @location_uuid, @other_location_uuid, actor)

      source_entry = Turnover.compute(@location_uuid, today(), today()) |> entry_for(item.uuid)

      dest_entry =
        Turnover.compute(@other_location_uuid, today(), today()) |> entry_for(item.uuid)

      assert Decimal.equal?(source_entry.outflow, Decimal.new("4"))
      assert Decimal.equal?(source_entry.inflow, Decimal.new("0"))
      assert dest_entry == nil
    end

    test "receiving counts as inflow at the destination only once actually received" do
      actor = user_uuid()
      item = create_item!()
      {:ok, _} = Warehouse.upsert_quantity(item.uuid, "10", location_uuid: @location_uuid)
      shipped = ship_transfer!(item.uuid, "4", @location_uuid, @other_location_uuid, actor)

      refute Turnover.compute(@other_location_uuid, today(), today()) |> entry_for(item.uuid)

      {:ok, _received} = Transfers.receive_transfer(shipped, actor)

      dest_entry =
        Turnover.compute(@other_location_uuid, today(), today()) |> entry_for(item.uuid)

      assert Decimal.equal?(dest_entry.inflow, Decimal.new("4"))
      assert Decimal.equal?(dest_entry.outflow, Decimal.new("0"))
    end
  end
end
