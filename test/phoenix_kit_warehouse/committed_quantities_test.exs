defmodule PhoenixKitWarehouse.CommittedQuantitiesTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.CommittedQuantities
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsIssues

  @default_location_uuid "00000000-0000-0000-0000-000000000001"

  defp create_issue!(attrs) do
    {:ok, issue} =
      GoodsIssues.create_goods_issue(Map.merge(%{location_uuid: @default_location_uuid}, attrs))

    issue
  end

  describe "compute/4" do
    test "sums the lines breakdown across multiple documents referencing the same source" do
      source_uuid = Ecto.UUID.generate()
      item_uuid = Ecto.UUID.generate()

      create_issue!(%{
        lines: [],
        source_refs: [
          %{
            "type" => "internal_order",
            "uuid" => source_uuid,
            "lines" => %{item_uuid => Decimal.new("3")}
          }
        ]
      })

      create_issue!(%{
        lines: [],
        source_refs: [
          %{
            "type" => "internal_order",
            "uuid" => source_uuid,
            "lines" => %{item_uuid => Decimal.new("2")}
          }
        ]
      })

      result =
        CommittedQuantities.compute(
          GoodsIssue,
          ["internal_order"],
          [source_uuid],
          "issued_quantity"
        )

      assert Decimal.equal?(result[source_uuid][item_uuid], Decimal.new("5"))
    end

    test "falls back to the document's own aggregate line quantity when a ref has no lines breakdown" do
      source_uuid = Ecto.UUID.generate()
      item_uuid = Ecto.UUID.generate()

      create_issue!(%{
        lines: [%{"item_uuid" => item_uuid, "issued_quantity" => Decimal.new("7")}],
        source_refs: [%{"type" => "internal_order", "uuid" => source_uuid}]
      })

      result =
        CommittedQuantities.compute(
          GoodsIssue,
          ["internal_order"],
          [source_uuid],
          "issued_quantity"
        )

      assert Decimal.equal?(result[source_uuid][item_uuid], Decimal.new("7"))
    end

    test "ignores soft-deleted documents" do
      source_uuid = Ecto.UUID.generate()
      item_uuid = Ecto.UUID.generate()

      issue =
        create_issue!(%{
          lines: [],
          source_refs: [
            %{
              "type" => "internal_order",
              "uuid" => source_uuid,
              "lines" => %{item_uuid => Decimal.new("4")}
            }
          ]
        })

      {:ok, _} = GoodsIssues.soft_delete(issue, Ecto.UUID.generate())

      result =
        CommittedQuantities.compute(
          GoodsIssue,
          ["internal_order"],
          [source_uuid],
          "issued_quantity"
        )

      assert result[source_uuid] in [nil, %{}]
    end

    test "ignores unrelated ref types and unrelated source uuids" do
      source_uuid = Ecto.UUID.generate()
      other_uuid = Ecto.UUID.generate()
      item_uuid = Ecto.UUID.generate()

      create_issue!(%{
        lines: [],
        source_refs: [
          %{
            "type" => "order",
            "uuid" => source_uuid,
            "lines" => %{item_uuid => Decimal.new("9")}
          },
          %{
            "type" => "internal_order",
            "uuid" => other_uuid,
            "lines" => %{item_uuid => Decimal.new("9")}
          }
        ]
      })

      result =
        CommittedQuantities.compute(
          GoodsIssue,
          ["internal_order"],
          [source_uuid],
          "issued_quantity"
        )

      assert result[source_uuid] in [nil, %{}]
    end
  end

  describe "merge_ref/4" do
    test "appends a new ref with its lines breakdown when none exists yet" do
      item_uuid = Ecto.UUID.generate()
      source_uuid = Ecto.UUID.generate()

      refs =
        CommittedQuantities.merge_ref([], "internal_order", source_uuid, %{
          item_uuid => Decimal.new("5")
        })

      assert [%{"type" => "internal_order", "uuid" => ^source_uuid, "lines" => lines}] = refs
      assert Decimal.equal?(lines[item_uuid], Decimal.new("5"))
    end

    test "sums onto an existing ref's lines in place instead of skipping or replacing" do
      item_uuid = Ecto.UUID.generate()
      source_uuid = Ecto.UUID.generate()

      existing = [
        %{
          "type" => "internal_order",
          "uuid" => source_uuid,
          "lines" => %{item_uuid => Decimal.new("3")}
        }
      ]

      refs =
        CommittedQuantities.merge_ref(existing, "internal_order", source_uuid, %{
          item_uuid => Decimal.new("2")
        })

      assert [%{"uuid" => ^source_uuid, "lines" => lines}] = refs
      assert Decimal.equal?(lines[item_uuid], Decimal.new("5"))
      assert length(refs) == 1
    end

    test "leaves other refs untouched" do
      source_uuid = Ecto.UUID.generate()
      other_uuid = Ecto.UUID.generate()
      item_uuid = Ecto.UUID.generate()

      existing = [%{"type" => "order", "uuid" => other_uuid}]

      refs =
        CommittedQuantities.merge_ref(existing, "internal_order", source_uuid, %{
          item_uuid => Decimal.new("1")
        })

      assert length(refs) == 2

      assert %{"type" => "order", "uuid" => ^other_uuid} =
               Enum.find(refs, &(&1["type"] == "order"))
    end
  end
end
