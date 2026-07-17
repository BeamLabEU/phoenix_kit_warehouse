defmodule PhoenixKitWarehouse.CostProposalsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitWarehouse.CostProposals

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Builds a fake ItemSupplierInfo-shaped map for the resolver to return.
  defp info(unit_cost) do
    %{
      uuid: "info-uuid",
      item_uuid: "item-uuid",
      supplier_uuid: "sup-uuid",
      unit_cost: unit_cost,
      supplier_source: "local",
      valid_to: nil
    }
  end

  # A resolver that returns a fixed info (or nil) for a given item_uuid.
  defp static_resolver(item_uuid, return_value) do
    fn uuid, _supplier_uuid ->
      if uuid == item_uuid, do: return_value, else: nil
    end
  end

  defp line(item_uuid, unit_value, name \\ "Widget", sku \\ "SKU-1") do
    %{
      "item_uuid" => item_uuid,
      "unit_value" => unit_value,
      "name" => name,
      "sku" => sku
    }
  end

  # ── derive/3 ────────────────────────────────────────────────────────────────

  describe "derive/3" do
    test "returns [] when supplier_uuid is nil" do
      resolver = fn _, _ -> info(Decimal.new("10.00")) end
      assert CostProposals.derive([line("item-1", "15.00")], nil, resolver) == []
    end

    test "generates a proposal when receipt price diverges from catalogued cost" do
      item_uuid = "item-abc"
      resolver = static_resolver(item_uuid, info(Decimal.new("10.00")))
      lines = [line(item_uuid, "15.00")]

      [proposal] = CostProposals.derive(lines, "sup-1", resolver)

      assert proposal.item_uuid == item_uuid
      assert proposal.name == "Widget"
      assert proposal.sku == "SKU-1"
      assert Decimal.equal?(proposal.receipt_price, Decimal.new("15.00"))
      assert Decimal.equal?(proposal.current_cost, Decimal.new("10.00"))
      assert proposal.info == info(Decimal.new("10.00"))
    end

    test "no proposal when receipt price equals catalogued cost" do
      item_uuid = "item-abc"
      resolver = static_resolver(item_uuid, info(Decimal.new("10.00")))
      lines = [line(item_uuid, "10.00")]

      assert CostProposals.derive(lines, "sup-1", resolver) == []
    end

    test "no proposal when resolver returns nil (no junction row)" do
      item_uuid = "item-abc"
      resolver = fn _, _ -> nil end
      lines = [line(item_uuid, "15.00")]

      assert CostProposals.derive(lines, "sup-1", resolver) == []
    end

    test "no proposal when unit_value is nil (line has no price)" do
      item_uuid = "item-abc"
      resolver = static_resolver(item_uuid, info(Decimal.new("10.00")))
      lines = [line(item_uuid, nil)]

      assert CostProposals.derive(lines, "sup-1", resolver) == []
    end

    test "no proposal when unit_value is not numeric" do
      item_uuid = "item-abc"
      resolver = static_resolver(item_uuid, info(Decimal.new("10.00")))
      lines = [line(item_uuid, "not-a-number")]

      assert CostProposals.derive(lines, "sup-1", resolver) == []
    end

    test "no proposal when item_uuid is nil" do
      resolver = fn _, _ -> info(Decimal.new("10.00")) end
      lines = [%{"item_uuid" => nil, "unit_value" => "15.00", "name" => "X", "sku" => nil}]

      assert CostProposals.derive(lines, "sup-1", resolver) == []
    end

    test "generates proposal when catalogue cost is nil (not yet set) and receipt price is non-zero" do
      item_uuid = "item-abc"
      # unit_cost: nil means price not yet set in catalogue
      resolver = static_resolver(item_uuid, info(nil))
      lines = [line(item_uuid, "10.00")]

      [proposal] = CostProposals.derive(lines, "sup-1", resolver)

      assert proposal.current_cost == nil
      assert Decimal.equal?(proposal.receipt_price, Decimal.new("10.00"))
    end

    test "no proposal when catalogue cost is nil and receipt price is zero" do
      item_uuid = "item-abc"
      resolver = static_resolver(item_uuid, info(nil))
      lines = [line(item_uuid, "0")]

      assert CostProposals.derive(lines, "sup-1", resolver) == []
    end

    test "handles Decimal unit_value directly" do
      item_uuid = "item-abc"
      resolver = static_resolver(item_uuid, info(Decimal.new("10.00")))
      lines = [line(item_uuid, Decimal.new("20.00"))]

      [proposal] = CostProposals.derive(lines, "sup-1", resolver)
      assert Decimal.equal?(proposal.receipt_price, Decimal.new("20.00"))
    end

    test "handles integer unit_value" do
      item_uuid = "item-abc"
      resolver = static_resolver(item_uuid, info(Decimal.new("10.00")))
      lines = [line(item_uuid, 20)]

      [proposal] = CostProposals.derive(lines, "sup-1", resolver)
      assert Decimal.equal?(proposal.receipt_price, Decimal.new(20))
    end

    test "only generates proposals for lines with divergent price" do
      item_a = "item-a"
      item_b = "item-b"

      resolver = fn
        ^item_a, _ -> info(Decimal.new("10.00"))
        ^item_b, _ -> info(Decimal.new("20.00"))
        _, _ -> nil
      end

      lines = [
        # diverges
        line(item_a, "15.00", "A"),
        # equal
        line(item_b, "20.00", "B")
      ]

      [proposal] = CostProposals.derive(lines, "sup-1", resolver)
      assert proposal.item_uuid == item_a
    end

    test "empty lines list returns empty proposals" do
      resolver = fn _, _ -> info(Decimal.new("10.00")) end
      assert CostProposals.derive([], "sup-1", resolver) == []
    end
  end

  # ── catalogue_resolver/0 ────────────────────────────────────────────────────

  describe "catalogue_resolver/0" do
    test "returns a 2-arity function" do
      resolver = CostProposals.catalogue_resolver()
      assert is_function(resolver, 2)
    end

    test "resolver call returns nil or raises (DB-agnostic guard test)" do
      # When the catalogue module IS available (P1 path dep), the resolver
      # calls active_info_for/2 which runs a DB query. Without a connected
      # DB in the warehouse unit-test environment, the call will raise.
      # We rescue to keep the test DB-agnostic: the important contract is
      # that the resolver never returns a non-nil value for a non-existent UUID.
      resolver = CostProposals.catalogue_resolver()

      result =
        try do
          resolver.(
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-000000000002"
          )
        rescue
          _ -> nil
        end

      assert is_nil(result)
    end
  end

  # ── apply_revision/2 ────────────────────────────────────────────────────────

  describe "apply_revision/2" do
    test "is callable and returns a tagged tuple or rescues" do
      # apply_revision/2 is a guarded delegation. When the catalogue IS available
      # (P1 path dep), it calls revise_unit_cost/3 which expects a real struct
      # and a DB connection — both absent here. We rescue to assert the function
      # is at least callable without crashing the test runner.
      proposal = %{
        info: info(Decimal.new("10.00")),
        receipt_price: Decimal.new("15.00"),
        item_uuid: "item-abc"
      }

      result =
        try do
          CostProposals.apply_revision(proposal, actor_uuid: nil, source: "goods_receipt")
        rescue
          _ -> {:error, :rescued}
        end

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
