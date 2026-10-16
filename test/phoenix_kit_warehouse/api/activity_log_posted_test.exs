defmodule PhoenixKitWarehouse.API.ActivityLogPostedTest do
  @moduledoc """
  `ActivityLog.log_posted/2` for the three posting documents, with the
  `:metadata` option the API uses.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKit.Activity.Entry
  alias PhoenixKitWarehouse.ActivityLog
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.Inventories

  @location "00000000-0000-0000-0000-0000000000a7"

  defp entry(action, uuid) do
    Repo.one(from(e in Entry, where: e.action == ^action and e.resource_uuid == ^uuid))
  end

  test "a goods receipt entry carries the number, the reference and the extra metadata" do
    user = user!()
    item = Ecto.UUID.generate()

    {:ok, receipt} =
      GoodsReceipts.create_and_post(
        %{
          location_uuid: @location,
          external_ref: "ACC-1",
          lines: [%{"item_uuid" => item, "received_quantity" => "1"}]
        },
        user.uuid
      )

    ActivityLog.log_posted(receipt,
      actor: %{uuid: user.uuid},
      metadata: %{"via" => "api", "key_prefix" => "abcd1234"}
    )

    assert %Entry{} = entry = entry("warehouse.goods_receipt.posted", receipt.uuid)
    assert entry.module == "warehouse"
    assert entry.resource_type == "goods_receipt"
    assert entry.actor_uuid == user.uuid

    assert entry.metadata == %{
             "number" => to_string(receipt.number),
             "external_ref" => "ACC-1",
             "via" => "api",
             "key_prefix" => "abcd1234"
           }
  end

  test "a goods issue entry carries the reason and the reference" do
    user = user!()
    item = Ecto.UUID.generate()
    seed!(item, "5", @location)

    {:ok, issue} =
      GoodsIssues.create_and_post(
        %{
          location_uuid: @location,
          reason: "damage",
          external_ref: "ISS-1",
          lines: [%{"item_uuid" => item, "issued_quantity" => "1"}]
        },
        user.uuid
      )

    ActivityLog.log_posted(issue, actor: %{uuid: user.uuid})

    assert %Entry{metadata: metadata} = entry("warehouse.goods_issue.posted", issue.uuid)
    assert metadata["reason"] == "damage"
    assert metadata["external_ref"] == "ISS-1"
    assert metadata["number"] == to_string(issue.number)
  end

  test "the inventory entry keeps its action and gains the metadata option" do
    user = user!()

    {:ok, document} =
      Inventories.create_and_post(
        %{
          location_uuid: @location,
          lines: [%{"item_uuid" => Ecto.UUID.generate(), "counted_quantity" => "3"}]
        },
        user.uuid
      )

    ActivityLog.log_posted(document, actor: %{uuid: user.uuid}, metadata: %{"via" => "api"})

    assert %Entry{metadata: %{"via" => "api"}} =
             entry("warehouse.inventory.posted", document.uuid)
  end

  test "without the :metadata option the metadata is exactly what it was" do
    item = Ecto.UUID.generate()

    {:ok, document} =
      Inventories.create_and_post(
        %{location_uuid: @location, lines: [%{"item_uuid" => item, "counted_quantity" => "1"}]},
        nil
      )

    ActivityLog.log_posted(document, [])

    assert %Entry{metadata: metadata} = entry("warehouse.inventory.posted", document.uuid)
    assert metadata == %{"number" => to_string(document.number)}
  end

  test "an explicit :mode wins; with an actor and no :mode the module's default is manual" do
    user = user!()

    receipt = fn ->
      {:ok, receipt} =
        GoodsReceipts.create_and_post(
          %{
            location_uuid: @location,
            lines: [%{"item_uuid" => Ecto.UUID.generate(), "received_quantity" => "1"}]
          },
          user.uuid
        )

      receipt
    end

    {auto, manual} = {receipt.(), receipt.()}

    ActivityLog.log_posted(auto, actor: %{uuid: user.uuid}, mode: "auto")
    ActivityLog.log_posted(manual, actor: %{uuid: user.uuid})

    assert %Entry{mode: "auto"} = entry("warehouse.goods_receipt.posted", auto.uuid)
    assert %Entry{mode: "manual"} = entry("warehouse.goods_receipt.posted", manual.uuid)
  end

  describe "the log never decides the fate of a document" do
    setup do
      on_exit(fn ->
        Application.delete_env(:phoenix_kit_warehouse, :inventory_activity_logging)
      end)
    end

    defp posted_receipt do
      {:ok, receipt} =
        GoodsReceipts.create_and_post(
          %{
            location_uuid: @location,
            lines: [%{"item_uuid" => Ecto.UUID.generate(), "received_quantity" => "1"}]
          },
          nil
        )

      receipt
    end

    test "with :inventory_activity_logging off the entry is skipped and log_posted/2 answers :ok" do
      Application.put_env(:phoenix_kit_warehouse, :inventory_activity_logging, false)
      receipt = posted_receipt()

      assert :ok = ActivityLog.log_posted(receipt, metadata: %{"via" => "api"})
      assert entry("warehouse.goods_receipt.posted", receipt.uuid) == nil
      assert Repo.get!(GoodsReceipt, receipt.uuid).status == "posted"
    end

    test "an entry that core cannot write is swallowed and the document stays posted" do
      receipt = posted_receipt()

      # A pid cannot be encoded as JSON: the insert fails on the client side,
      # before any statement reaches the database (the sandbox transaction
      # stays usable). It is core's `Activity.log/1` that catches this.
      capture_log(fn ->
        assert :ok = ActivityLog.log_posted(receipt, metadata: %{"pid" => self()})
      end)

      assert Repo.get!(GoodsReceipt, receipt.uuid).status == "posted"
    end

    test "an error in the module itself is swallowed, and only its kind is logged" do
      receipt = posted_receipt()

      # A metadata that is not a map raises in `do_log/2`, before core is
      # called: this is the module's own rescue. Its message quotes the value.
      log =
        capture_log(fn ->
          assert :ok = ActivityLog.log_posted(receipt, metadata: "SECRET-REQUEST-VALUE")
        end)

      assert log =~ "[Warehouse.ActivityLog] log error: BadMapError"
      refute log =~ "SECRET-REQUEST-VALUE"
      assert entry("warehouse.goods_receipt.posted", receipt.uuid) == nil
      assert Repo.get!(GoodsReceipt, receipt.uuid).status == "posted"
    end

    test "an entry without API metadata keeps the message of the error in the log" do
      receipt = posted_receipt()

      # An actor that is not a map raises in `actor_uuid/1`: the module's own rescue.
      log =
        capture_log(fn -> assert :ok = ActivityLog.log_posted(receipt, actor: "not-an-actor") end)

      assert log =~ "[Warehouse.ActivityLog] log error: no case clause matching"
    end
  end
end
