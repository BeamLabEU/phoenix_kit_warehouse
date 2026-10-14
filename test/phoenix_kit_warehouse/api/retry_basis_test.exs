defmodule PhoenixKitWarehouse.API.RetryBasisTest do
  @moduledoc """
  A repeated `external_ref` is answered `skipped` from the posted document.
  Only a request that matches that document passes for a plain retry: a
  warehouse, catalogue, reason or order that differs is reported in the
  answer, and a malformed source is refused as in a first call.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKitWarehouse.API.Write
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.Test.ApiOrders, as: Orders

  setup do
    %{locations: [first, second]} = warehouses!(2)
    catalogue = shop_catalogue!()
    user = user!()

    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :source_kinds) end)

    %{
      first: first,
      second: second,
      catalogue: catalogue,
      a: item!(catalogue),
      ctx: ctx(user),
      dry: ctx(user, %{dry_run?: true})
    }
  end

  defp line(item, quantity), do: %{"ref" => %{"id" => item.uuid}, "quantity" => quantity}

  defp effects({:ok, _body}), do: []
  defp effects({:ok, _body, effects}), do: effects
  defp effects({:preview, %{"effects" => effects}, _fingerprint}), do: effects
  defp effects({:preview, _body, _fingerprint}), do: []

  defp codes(result), do: result |> effects() |> Enum.map(& &1["code"])

  defp body({:ok, body}), do: body
  defp body({:ok, body, _effects}), do: body
  defp body({:preview, body, _fingerprint}), do: body

  # A document posted long enough ago for its first call to have finished.
  defp age!(id) do
    at = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    {1, _} = Repo.update_all(from(i in GoodsIssue, where: i.uuid == ^id), set: [posted_at: at])
    :ok
  end

  defp register_orders(uuid) do
    Orders.put(uuid, "Order #1001")
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [Orders.kind()])
    uuid
  end

  describe "one reference on three kinds of document" do
    test "a receipt, an issue and a stocktake with one external_ref are three documents", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "10", first.uuid)
      ref = "X-1"
      lines = [line(a, "1")]

      calls = [
        {"goods_receipt", &Write.receive_stock/2, %{"external_ref" => ref, "lines" => lines}},
        {"goods_issue", &Write.issue_stock/2,
         %{"external_ref" => ref, "reason" => "sale", "lines" => lines}},
        {"inventory", &Write.set_stock/2, %{"external_ref" => ref, "lines" => lines}}
      ]

      posted =
        for {type, call, input} <- calls do
          assert {:ok, %{"status" => "posted", "document" => %{"type" => ^type, "id" => id}}} =
                   call.(input, ctx)

          id
        end

      assert length(Enum.uniq(posted)) == 3

      # Each is retried on its own: it answers its own document.
      for {{type, call, input}, id} <- Enum.zip(calls, posted) do
        assert {:ok, %{"status" => "skipped", "document" => %{"type" => ^type, "id" => ^id}}} =
                 call.(input, ctx)
      end

      assert Repo.aggregate(GoodsReceipt, :count) == 1
      assert Repo.aggregate(GoodsIssue, :count) == 1
      assert Repo.aggregate(PhoenixKitWarehouse.InventoryDocument, :count) == 1
    end
  end

  describe "the warehouse" do
    test "a receipt reference reused for another warehouse says so and moves no stock", %{
      first: first,
      second: second,
      a: a,
      ctx: ctx
    } do
      input = %{"external_ref" => "RB-LOC-1", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.receive_stock(input, ctx)

      result = Write.receive_stock(Map.put(input, "location_id", second.uuid), ctx)

      assert {:ok, %{"status" => "skipped", "document" => %{"location_id" => location}}, [effect]} =
               result

      assert location == first.uuid
      assert effect["code"] == "external_ref_basis_differs"
      assert effect["message"] =~ "location_id"
      assert Decimal.equal?(quantity(a.uuid, second.uuid), Decimal.new(0))
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(5))
    end

    test "a stocktake reference reused for another warehouse says so", %{
      second: second,
      a: a,
      ctx: ctx
    } do
      input = %{"external_ref" => "RB-LOC-2", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.set_stock(input, ctx)

      result = Write.set_stock(Map.put(input, "location_id", second.uuid), ctx)

      assert {:ok, %{"status" => "skipped"}, [%{"code" => "external_ref_basis_differs"}]} = result
      assert Decimal.equal?(quantity(a.uuid, second.uuid), Decimal.new(0))
    end

    test "a location that does not exist is reported, not refused, on a retry", %{
      a: a,
      ctx: ctx
    } do
      input = %{"external_ref" => "RB-LOC-3", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.receive_stock(input, ctx)

      for bad <- [Ecto.UUID.generate(), "nope", 5] do
        result = Write.receive_stock(Map.put(input, "location_id", bad), ctx)
        assert {:ok, %{"status" => "skipped"}, [_effect]} = result
        assert codes(result) == ["external_ref_basis_differs"]
      end
    end

    test "the same warehouse, named or defaulted, is a plain retry even after the default moved",
         %{first: first, second: second, a: a, ctx: ctx} do
      input = %{"external_ref" => "RB-LOC-4", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.receive_stock(input, ctx)

      assert {:ok, %{"status" => "skipped"}} =
               Write.receive_stock(Map.put(input, "location_id", first.uuid), ctx)

      assert {:ok, %{"status" => "skipped"}} =
               Write.receive_stock(Map.put(input, "location_id", String.upcase(first.uuid)), ctx)

      PhoenixKitWarehouse.StockLedger.set_default_location_uuid(second.uuid)
      assert {:ok, %{"status" => "skipped"}} = Write.receive_stock(input, ctx)
    end

    test "a preview of the retry carries the same effect", %{
      second: second,
      a: a,
      ctx: ctx,
      dry: dry
    } do
      input = %{"external_ref" => "RB-LOC-5", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.receive_stock(input, ctx)

      result = Write.receive_stock(Map.put(input, "location_id", second.uuid), dry)

      assert %{"status" => "would_skip"} = body(result)
      assert codes(result) == ["external_ref_basis_differs"]
    end
  end

  describe "the catalogue" do
    test "a reference reused with another catalogue says so", %{a: a, ctx: ctx} do
      input = %{"external_ref" => "RB-CAT-1", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.receive_stock(input, ctx)
      other = catalogue!()

      assert {:ok, %{"status" => "skipped"}} =
               Write.receive_stock(Map.put(input, "catalogue_id", a.catalogue_uuid), ctx)

      result = Write.receive_stock(Map.put(input, "catalogue_id", other.uuid), ctx)
      assert "external_ref_basis_differs" in codes(result)

      for garbage <- [Ecto.UUID.generate(), "not-a-uuid", "0123456789abcdef", 5] do
        result = Write.receive_stock(Map.put(input, "catalogue_id", garbage), ctx)
        assert "external_ref_basis_differs" in codes(result), inspect(garbage)
      end
    end

    test "a catalogue that was archived or deleted since the first call is still the same one",
         %{catalogue: catalogue, a: a, ctx: ctx} do
      input = %{
        "external_ref" => "RB-CAT-2",
        "catalogue_id" => catalogue.uuid,
        "lines" => [line(a, "5")]
      }

      assert {:ok, %{"status" => "posted"}} = Write.receive_stock(input, ctx)

      for status <- ["archived", "deleted"],
          id <- [catalogue.uuid, String.upcase(catalogue.uuid)] do
        set_catalogue_status!(catalogue, status)
        result = Write.receive_stock(Map.put(input, "catalogue_id", id), ctx)

        assert {:ok, %{"status" => "skipped"}, _effects} = result
        refute "external_ref_basis_differs" in codes(result), "#{status} #{id}"
      end
    end
  end

  describe "the reason of an issue" do
    test "a reference reused with another reason says so and writes off nothing more", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "10", first.uuid)
      input = %{"external_ref" => "RB-REASON-1", "reason" => "sale", "lines" => [line(a, "2")]}
      assert {:ok, %{"status" => "posted"}} = Write.issue_stock(input, ctx)

      assert {:ok, %{"status" => "skipped"}} = Write.issue_stock(input, ctx)

      result = Write.issue_stock(Map.put(input, "reason", "damage"), ctx)

      assert {:ok, %{"status" => "skipped", "document" => %{"reason" => "sale"}}, [effect]} =
               result

      assert effect["code"] == "external_ref_basis_differs"
      assert effect["message"] =~ "reason"
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(8))
    end
  end

  describe "the order of an issue" do
    setup %{first: first, a: a} do
      seed!(a.uuid, "10", first.uuid)
      %{order: register_orders(Ecto.UUID.generate())}
    end

    defp crashed_issue(a, ctx) do
      # The state after a crash between the posting and the link to the order.
      input = %{"external_ref" => "RB-ORDER-1", "reason" => "sale", "lines" => [line(a, "1")]}

      assert {:ok, %{"status" => "posted", "document" => %{"id" => id}}} =
               Write.issue_stock(input, ctx)

      {input, id}
    end

    test "a retry that names an order the document is not linked to says so", %{
      a: a,
      ctx: ctx,
      order: order
    } do
      {input, id} = crashed_issue(a, ctx)
      age!(id)
      retry = Map.put(input, "source", %{"kind" => "shop_order", "id" => order})

      result = Write.issue_stock(retry, ctx)

      assert {:ok, %{"status" => "skipped"}, [effect]} = result
      assert effect["code"] == "source_ref_not_attached"
      assert Repo.get!(GoodsIssue, id).source_refs == []
    end

    test "a retry right behind the first call, before it linked the order, is not told the link is missing",
         %{a: a, ctx: ctx, dry: dry, order: order} do
      # The first call links the order after its posting committed; a retry
      # that reads the document in between sees no link yet.
      {input, id} = crashed_issue(a, ctx)
      retry = Map.put(input, "source", %{"kind" => "shop_order", "id" => order})

      assert {:ok, %{"status" => "skipped"}} = Write.issue_stock(retry, ctx)
      assert {:ok, %{"status" => "skipped"}} = Write.run_new(:issue, retry, ctx)
      assert codes(Write.issue_stock(retry, dry)) == []
      assert Repo.get!(GoodsIssue, id).source_refs == []

      age!(id)
      assert codes(Write.issue_stock(retry, ctx)) == ["source_ref_not_attached"]
      assert codes(Write.run_new(:issue, retry, ctx)) == ["source_ref_not_attached"]
      assert codes(Write.issue_stock(retry, dry)) == ["source_ref_not_attached"]
    end

    test "a retry that names another order than the linked one says so", %{
      a: a,
      first: first,
      ctx: ctx,
      order: order
    } do
      input = %{
        "external_ref" => "RB-ORDER-2",
        "reason" => "sale",
        "source" => %{"kind" => "shop_order", "id" => order},
        "lines" => [line(a, "1")]
      }

      assert {:ok, %{"status" => "posted"}} = Write.issue_stock(input, ctx)
      assert {:ok, %{"status" => "skipped"}} = Write.issue_stock(input, ctx)

      other = register_orders(Ecto.UUID.generate())
      retry = put_in(input, ["source", "id"], other)

      assert {:ok, %{"status" => "skipped"}, [%{"code" => "source_ref_not_attached"}]} =
               Write.issue_stock(retry, ctx)

      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(9))
    end

    test "a retry of an issue with no order needs no effect", %{a: a, ctx: ctx} do
      {input, _id} = crashed_issue(a, ctx)
      assert {:ok, %{"status" => "skipped"}} = Write.issue_stock(input, ctx)
    end
  end

  describe "a source that is not valid" do
    setup %{first: first, a: a, ctx: ctx} do
      seed!(a.uuid, "10", first.uuid)
      order = register_orders(Ecto.UUID.generate())

      assert {:ok, %{"status" => "posted"}} =
               Write.issue_stock(
                 %{
                   "reason" => "sale",
                   "source" => %{"kind" => "external", "ref" => "RB-SRC-1"},
                   "lines" => [line(a, "1")]
                 },
                 ctx
               )

      %{order: order}
    end

    test "is refused on a retry as in a first call, not answered skipped", %{
      a: a,
      ctx: ctx,
      order: order
    } do
      lines = [line(a, "1")]

      # An external source with a key it does not have: it names the same
      # reference as the posted document, and still is not a retry.
      extra = %{"kind" => "external", "ref" => "RB-SRC-1", "id" => order}

      assert {:error, :validation_failed, _message, %{errors: [%{path: "source"}], posted: false}} =
               Write.issue_stock(%{"reason" => "sale", "source" => extra, "lines" => lines}, ctx)

      # A shop order source that is malformed, with the reference of the posted document.
      for {source, path} <- [
            {%{"kind" => "shop_order", "id" => "not-a-uuid"}, "source.id"},
            {%{"kind" => "shop_order", "id" => Ecto.UUID.dump!(order)}, "source.id"},
            {%{"kind" => "shop_order", "id" => order, "ref" => "RB-SRC-1"}, "source"}
          ] do
        input = %{
          "external_ref" => "RB-SRC-1",
          "reason" => "sale",
          "source" => source,
          "lines" => lines
        }

        assert {:error, :validation_failed, _message, %{errors: [%{path: ^path}], posted: false}} =
                 Write.issue_stock(input, ctx)
      end
    end
  end

  describe "a retry that raced past the early lookup" do
    # `Write.run_new/3` skips the early lookup, so the posting layer is the
    # one that answers `already_posted`: what a retry racing the first call
    # gets.
    defp activity_entries(id),
      do:
        Repo.aggregate(
          from(e in PhoenixKit.Activity.Entry, where: e.resource_uuid == ^id),
          :count
        )

    defp posted_receipt(a, ctx, ref, quantity \\ "5") do
      input = %{"external_ref" => ref, "lines" => [line(a, quantity)]}

      assert {:ok, %{"status" => "posted", "document" => %{"id" => id}}} =
               Write.receive_stock(input, ctx)

      {input, id}
    end

    test "a plain retry is skipped: no effect, no second document, no second Activity entry", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      {input, id} = posted_receipt(a, ctx, "RB-RACE-1")
      entries = activity_entries(id)
      assert entries >= 1

      assert {:ok,
              %{
                "status" => "skipped",
                "document" => %{"id" => ^id},
                "results" => [%{"action" => "skipped"}],
                "summary" => %{"skipped" => 1}
              }} = Write.run_new(:receipt, input, ctx)

      assert activity_entries(id) == entries
      assert Repo.aggregate(GoodsReceipt, :count) == 1
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(5))
    end

    test "other lines are reported", %{a: a, ctx: ctx} do
      {input, _id} = posted_receipt(a, ctx, "RB-RACE-2")
      other = Map.put(input, "lines", [line(a, "6")])

      assert codes(Write.run_new(:receipt, other, ctx)) == ["external_ref_lines_differ"]
    end

    test "a stocktake is compared too", %{a: a, ctx: ctx} do
      input = %{"external_ref" => "RB-RACE-3", "lines" => [line(a, "5")]}
      assert {:ok, %{"status" => "posted"}} = Write.set_stock(input, ctx)

      assert {:ok, %{"status" => "skipped"}} = Write.run_new(:inventory, input, ctx)

      other = Map.put(input, "lines", [line(a, "7")])
      assert codes(Write.run_new(:inventory, other, ctx)) == ["external_ref_lines_differ"]
    end

    test "another warehouse that is stated is reported; the default, moved since, is not", %{
      second: second,
      a: a,
      ctx: ctx
    } do
      {input, _id} = posted_receipt(a, ctx, "RB-RACE-4")

      result = Write.run_new(:receipt, Map.put(input, "location_id", second.uuid), ctx)
      assert codes(result) == ["external_ref_basis_differs"]
      assert [%{"message" => message}] = effects(result)
      assert message =~ "location_id"

      PhoenixKitWarehouse.StockLedger.set_default_location_uuid(second.uuid)
      assert {:ok, %{"status" => "skipped"}} = Write.run_new(:receipt, input, ctx)
    end

    test "another catalogue that is stated is reported; the same one is not", %{a: a, ctx: ctx} do
      {input, _id} = posted_receipt(a, ctx, "RB-RACE-4C")

      same = Map.put(input, "catalogue_id", a.catalogue_uuid)
      assert {:ok, %{"status" => "skipped"}} = Write.run_new(:receipt, same, ctx)

      # The lines are read within the stated catalogue, so they name a product of
      # it; they differ from the posted ones too.
      other_catalogue = catalogue!()
      other_item = item!(other_catalogue)

      other =
        input
        |> Map.put("catalogue_id", other_catalogue.uuid)
        |> Map.put("lines", [line(other_item, "5")])

      result = Write.run_new(:receipt, other, ctx)
      assert "external_ref_basis_differs" in codes(result)

      assert %{"message" => message} =
               Enum.find(effects(result), &(&1["code"] == "external_ref_basis_differs"))

      assert message =~ "catalogue_id"
    end

    test "another reason is reported", %{first: first, a: a, ctx: ctx} do
      seed!(a.uuid, "10", first.uuid)
      input = %{"external_ref" => "RB-RACE-5", "reason" => "sale", "lines" => [line(a, "2")]}
      assert {:ok, %{"status" => "posted"}} = Write.issue_stock(input, ctx)

      assert {:ok, %{"status" => "skipped"}} = Write.run_new(:issue, input, ctx)

      result = Write.run_new(:issue, Map.put(input, "reason", "damage"), ctx)
      assert codes(result) == ["external_ref_basis_differs"]
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(8))
    end
  end
end
