defmodule PhoenixKitWarehouse.API.ReceiveStockTest do
  @moduledoc """
  `warehouse.receive_stock`: a multi-line goods receipt created and posted in
  one transaction, with exact `{from, to}`, `external_ref` idempotency, and
  an atomic refusal when anything in the request is wrong.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKit.Activity.Entry
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.API.Write
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.Stock

  setup do
    %{locations: [first, second]} = warehouses!(2)
    catalogue = shop_catalogue!()
    user = user!()

    %{
      first: first,
      second: second,
      catalogue: catalogue,
      a: item!(catalogue),
      b: item!(catalogue),
      user: user,
      ctx: ctx(user)
    }
  end

  defp line(item, quantity, extra \\ %{}),
    do: Map.merge(%{"ref" => %{"id" => item.uuid}, "quantity" => quantity}, extra)

  defp receive!(input, ctx) do
    assert {:ok, body} = Write.receive_stock(input, ctx)
    body
  end

  defp refused(input, ctx) do
    assert {:error, :validation_failed, message, %{errors: errors, posted: false}} =
             Write.receive_stock(input, ctx)

    assert is_binary(message)
    errors
  end

  defp counters do
    %{rows: [[last, called?]]} =
      Repo.query!(
        "SELECT last_value, is_called FROM phoenix_kit_warehouse_goods_receipts_number_seq"
      )

    %{
      receipts: Repo.aggregate(GoodsReceipt, :count),
      stock_rows: Repo.aggregate(Stock, :count),
      sequence: {last, called?}
    }
  end

  test "posts a multi-line receipt: stock moves, the document is posted by the key's owner", %{
    first: first,
    a: a,
    b: b,
    user: user,
    ctx: ctx
  } do
    seed!(a.uuid, "5", first.uuid)

    body =
      receive!(
        %{
          "lines" => [line(a, "3"), line(b, 2, %{"unit_value" => "1.5"})],
          "note" => "  delivery  "
        },
        ctx
      )

    assert body["status"] == "posted"

    assert %{
             "id" => id,
             "type" => "goods_receipt",
             "number" => number,
             "location_id" => location,
             "posted_at" => posted_at
           } =
             body["document"]

    assert is_integer(number) and location == first.uuid and is_binary(posted_at)

    assert [
             %{
               "ref" => %{"id" => a_id},
               "action" => "updated",
               "id" => a_id,
               "from" => "5",
               "to" => "8"
             },
             %{"id" => b_id, "action" => "updated", "from" => "0", "to" => "2"}
           ] = body["results"]

    assert a_id == a.uuid and b_id == b.uuid
    assert body["summary"] == %{"updated" => 2}

    assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(8))
    assert Decimal.equal?(quantity(b.uuid, first.uuid), Decimal.new(2))

    receipt = Repo.get!(GoodsReceipt, id)
    assert receipt.status == "posted"
    assert receipt.created_by_uuid == user.uuid and receipt.performed_by_uuid == user.uuid
    assert receipt.note == "delivery"

    b_stock = Repo.get_by!(Stock, item_uuid: b.uuid, location_uuid: first.uuid)
    assert Decimal.equal?(b_stock.unit_value, Decimal.new("1.5"))
  end

  test "an explicit location_id wins over the default", %{second: second, a: a, ctx: ctx} do
    body = receive!(%{"location_id" => second.uuid, "lines" => [line(a, "1")]}, ctx)

    assert body["document"]["location_id"] == second.uuid
    assert Decimal.equal?(quantity(a.uuid, second.uuid), Decimal.new(1))
  end

  describe "external_ref" do
    test "is stored trimmed, and a retry answers skipped with the existing number and moves nothing",
         %{
           first: first,
           a: a,
           ctx: ctx
         } do
      input = %{"external_ref" => "  ACC-77 ", "lines" => [line(a, "4")]}

      posted = receive!(input, ctx)
      assert posted["document"]["external_ref"] == "ACC-77"

      before = counters()
      again = receive!(input, ctx)

      assert again["status"] == "skipped"
      assert again["document"]["number"] == posted["document"]["number"]
      assert again["document"]["id"] == posted["document"]["id"]
      assert [%{"action" => "skipped", "id" => id}] = again["results"]
      assert id == a.uuid
      assert again["summary"] == %{"skipped" => 1}
      refute Map.has_key?(hd(again["results"]), "from")

      assert counters() == before
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(4))
    end

    test "a whitespace-only, empty, oversized or non-string reference is refused", %{
      a: a,
      ctx: ctx
    } do
      for bad <- ["   ", "", String.duplicate("x", 256), 5, ["x"], "bad\nref"] do
        errors = refused(%{"external_ref" => bad, "lines" => [line(a, "1")]}, ctx)
        assert [%{path: "external_ref", code: "validation_failed"}] = errors, inspect(bad)
      end

      assert %{"status" => "posted"} =
               receive!(
                 %{"external_ref" => String.duplicate("x", 255), "lines" => [line(a, "1")]},
                 ctx
               )
    end

    test "a retry is answered from the document even when the world moved on since (trashed product, other default warehouse)",
         %{
           first: first,
           second: second,
           a: a,
           ctx: ctx
         } do
      input = %{"external_ref" => "ACC-80", "lines" => [line(a, "4")]}
      posted = receive!(input, ctx)

      {:ok, _} = Catalogue.trash_item(a)
      PhoenixKitWarehouse.StockLedger.set_default_location_uuid(second.uuid)

      assert {:ok, again, [effect]} = Write.receive_stock(input, ctx)
      assert again["status"] == "skipped"
      assert again["document"]["number"] == posted["document"]["number"]
      assert again["document"]["location_id"] == first.uuid
      assert [%{"ref" => %{"id" => ref_id}, "action" => "skipped", "id" => id}] = again["results"]
      assert {ref_id, id} == {a.uuid, a.uuid}
      assert effect["code"] == "external_ref_lines_unverified"
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(4))
    end

    test "a reference reused with other lines is refused, naming the posted document, and moves no stock",
         %{
           first: first,
           a: a,
           b: b,
           ctx: ctx
         } do
      posted = receive!(%{"external_ref" => "ACC-81", "lines" => [line(a, "4")]}, ctx)
      before = counters()

      for other <- [[line(a, "5")], [line(b, "4")], [line(a, "4"), line(b, "1")]] do
        assert {:error, :validation_failed, _message, context} =
                 Write.receive_stock(%{"external_ref" => "ACC-81", "lines" => other}, ctx)

        assert context.posted == false
        assert context.document["number"] == posted["document"]["number"]

        assert [%{path: "lines", code: "external_ref_lines_differ"} = error] =
                 context.errors

        assert error.message =~ "new external_ref"
      end

      assert counters() == before
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(4))
      assert Decimal.equal?(quantity(b.uuid, first.uuid), Decimal.new(0))
    end

    test "a reference reused with another unit_value is refused and keeps the stored one",
         %{first: first, a: a, ctx: ctx} do
      priced = fn unit_value -> [line(a, "3", %{"unit_value" => unit_value})] end
      receive!(%{"external_ref" => "ACC-82", "lines" => priced.("5")}, ctx)

      refused = fn lines ->
        assert {:error, :validation_failed, _message, %{errors: errors, posted: false}} =
                 Write.receive_stock(%{"external_ref" => "ACC-82", "lines" => lines}, ctx)

        Enum.map(errors, & &1.code)
      end

      assert refused.(priced.("9")) == ["external_ref_lines_differ"]
      # a retry that leaves the unit value out is not the posted request either
      assert refused.([line(a, "3")]) == ["external_ref_lines_differ"]

      stock = Repo.get_by!(Stock, item_uuid: a.uuid, location_uuid: first.uuid)
      assert Decimal.equal?(stock.unit_value, Decimal.new(5))
      assert Decimal.equal?(stock.quantity, Decimal.new(3))
    end

    test "the same unit_value written differently, or none on both calls, is a plain retry", %{
      a: a,
      b: b,
      ctx: ctx
    } do
      receive!(
        %{
          "external_ref" => "ACC-83",
          "lines" => [line(a, "3", %{"unit_value" => "5"}), line(b, "1")]
        },
        ctx
      )

      same = [line(a, "3", %{"unit_value" => "5.00"}), line(b, "1")]

      assert {:ok, %{"status" => "skipped"}} =
               Write.receive_stock(%{"external_ref" => "ACC-83", "lines" => same}, ctx)

      # a unit value where the posted line had none
      priced_b = [line(a, "3", %{"unit_value" => "5"}), line(b, "1", %{"unit_value" => "2"})]

      assert {:error, :validation_failed, _message,
              %{errors: [%{code: "external_ref_lines_differ"}], posted: false}} =
               Write.receive_stock(%{"external_ref" => "ACC-83", "lines" => priced_b}, ctx)
    end
  end

  describe "an atomic refusal posts nothing" do
    test "an unknown product: not_found at lines[i].ref, no document, no stock row, no number burnt",
         %{
           a: a,
           ctx: ctx
         } do
      before = counters()
      ghost = %{"id" => Ecto.UUID.generate()}

      errors = refused(%{"lines" => [line(a, "1"), %{"ref" => ghost, "quantity" => "1"}]}, ctx)

      assert [%{path: "lines[1].ref", code: "not_found"}] = errors
      assert counters() == before
    end

    test "a duplicate product, also under a differently written id: duplicate_line", %{
      a: a,
      ctx: ctx
    } do
      before = counters()

      lines = [line(a, "1"), %{"ref" => %{"id" => String.upcase(a.uuid)}, "quantity" => "2"}]

      assert [%{path: "lines[1]", code: "duplicate_line", first_line: 0}] =
               refused(%{"lines" => lines}, ctx)

      assert counters() == before
    end

    if Code.ensure_loaded?(PhoenixKitCatalogue.API) and
         function_exported?(PhoenixKitCatalogue.API, :resolve_refs, 2) do
      test "the same product as an id and as a sku: duplicate_line, nothing posted", %{
        a: a,
        ctx: ctx
      } do
        before = counters()

        lines = [line(a, "1"), %{"ref" => %{"sku" => a.sku}, "quantity" => "2"}]

        assert [%{path: "lines[1]", code: "duplicate_line", first_line: 0}] =
                 refused(%{"lines" => lines}, ctx)

        assert counters() == before
      end

      test "an ambiguous sku is refused with the candidates on the line's ref", %{
        catalogue: catalogue,
        a: a,
        ctx: ctx
      } do
        twin_one = item!(catalogue, %{sku: "TWIN-WRITE"})
        twin_two = item!(catalogue, %{sku: "TWIN-WRITE"})
        before = counters()

        lines = [line(a, "1"), %{"ref" => %{"sku" => "TWIN-WRITE"}, "quantity" => "1"}]

        assert [%{path: "lines[1].ref", code: "ambiguous_ref", candidates: candidates}] =
                 refused(%{"lines" => lines}, ctx)

        assert Enum.sort(candidates) == Enum.sort([twin_one.uuid, twin_two.uuid])
        assert counters() == before
      end
    end

    test "quantities: zero, negative, exponent and 7 places are refused at lines[i].quantity", %{
      a: a,
      ctx: ctx
    } do
      for bad <- ["0", 0, "-1", "1e999999", "1.0000001", true, nil] do
        assert [%{path: "lines[0].quantity", code: "validation_failed"}] =
                 refused(%{"lines" => [%{"ref" => %{"id" => a.uuid}, "quantity" => bad}]}, ctx),
               inspect(bad)
      end
    end

    test "every problem is reported in one answer", %{a: a, ctx: ctx} do
      errors =
        refused(
          %{
            "location_id" => Ecto.UUID.generate(),
            "note" => String.duplicate("n", 1001),
            "lines" => [
              %{"ref" => %{"id" => Ecto.UUID.generate()}, "quantity" => "x"},
              line(a, "1"),
              line(a, "1")
            ]
          },
          ctx
        )

      assert Enum.sort(Enum.map(errors, & &1.path)) ==
               Enum.sort(["location_id", "note", "lines[0].ref", "lines[0].quantity", "lines[2]"])
    end

    test "a location that is not a warehouse, or no default at all, is refused at location_id", %{
      a: a,
      ctx: ctx
    } do
      assert [%{path: "location_id", message: message}] =
               refused(%{"location_id" => Ecto.UUID.generate(), "lines" => [line(a, "1")]}, ctx)

      assert message =~ "not a warehouse location"

      PhoenixKitWarehouse.StockLedger.set_default_location_uuid(nil)

      assert [%{path: "location_id", message: message}] =
               refused(%{"lines" => [line(a, "1")]}, ctx)

      assert message =~ "warehouse_default_location_uuid"
    end

    test "the 16 raw bytes of a catalogue's UUID do not name that catalogue", %{
      catalogue: catalogue,
      a: a,
      ctx: ctx
    } do
      before = counters()
      raw = Ecto.UUID.dump!(catalogue.uuid)

      assert [%{path: "catalogue_id", code: "validation_failed"}] =
               refused(%{"catalogue_id" => raw, "lines" => [line(a, "1")]}, ctx)

      assert counters() == before
    end

    test "a ref to an item of another catalogue is not found when catalogue_id is given", %{
      a: a,
      ctx: ctx
    } do
      other = catalogue!()

      assert [%{path: "lines[0].ref", code: "not_found"}] =
               refused(%{"catalogue_id" => other.uuid, "lines" => [line(a, "1")]}, ctx)
    end

    test "a catalogue_id that does not exist is refused at catalogue_id", %{a: a, ctx: ctx} do
      assert [%{path: "catalogue_id"}] =
               refused(%{"catalogue_id" => Ecto.UUID.generate(), "lines" => [line(a, "1")]}, ctx)
    end

    test "with two active catalogues catalogue_id is required, for an id ref too", %{
      a: a,
      ctx: ctx
    } do
      _second = catalogue!()
      before = counters()

      assert [%{path: "catalogue_id", code: "validation_failed"}] =
               refused(%{"lines" => [line(a, "1")]}, ctx)

      assert counters() == before

      assert %{"status" => "posted"} =
               receive!(%{"catalogue_id" => a.catalogue_uuid, "lines" => [line(a, "1")]}, ctx)
    end

    test "a deleted or archived catalogue is refused for a write", %{
      catalogue: catalogue,
      a: a,
      ctx: ctx
    } do
      for status <- ["archived", "deleted"] do
        set_catalogue_status!(catalogue, status)

        errors = refused(%{"catalogue_id" => catalogue.uuid, "lines" => [line(a, "1")]}, ctx)
        assert Enum.any?(errors, &match?(%{path: "catalogue_id"}, &1)), status
      end
    end
  end

  test "the module's own Activity entry names the key, the request, the tool and the warehouse",
       %{first: first, a: a, user: user, ctx: ctx} do
    body = receive!(%{"external_ref" => "ACC-9", "lines" => [line(a, "1")]}, ctx)

    entry =
      Repo.one!(
        from(e in Entry,
          where:
            e.action == "warehouse.goods_receipt.posted" and
              e.resource_uuid == ^body["document"]["id"]
        )
      )

    assert entry.actor_uuid == user.uuid
    assert entry.mode == "auto"

    assert %{
             "via" => "api",
             "key_prefix" => "abcd1234",
             "request_id" => "req-test",
             "tool" => "warehouse.receive_stock",
             "lines" => 1,
             "external_ref" => "ACC-9",
             "location_uuid" => location_uuid
           } = entry.metadata

    assert location_uuid == first.uuid

    refute Map.has_key?(entry.metadata, "approved_by_uuid")
  end

  test "an approved operation names the approver next to the actor", %{
    a: a,
    b: b,
    user: user,
    ctx: ctx
  } do
    approver = user!()

    approved =
      receive!(%{"lines" => [line(a, "1")]}, Map.put(ctx, :approved_by_uuid, approver.uuid))

    ordinary = receive!(%{"lines" => [line(b, "1")]}, ctx)

    entry_of = fn body ->
      Repo.one!(
        from(e in Entry,
          where:
            e.action == "warehouse.goods_receipt.posted" and
              e.resource_uuid == ^body["document"]["id"]
        )
      )
    end

    assert %Entry{actor_uuid: actor_uuid, metadata: %{"approved_by_uuid" => approved_by}} =
             entry_of.(approved)

    assert {actor_uuid, approved_by} == {user.uuid, approver.uuid}
    refute Map.has_key?(entry_of.(ordinary).metadata, "approved_by_uuid")
  end

  test "with the module's activity log switched off the document is still posted and no entry is written",
       %{a: a, ctx: ctx} do
    Application.put_env(:phoenix_kit_warehouse, :inventory_activity_logging, false)
    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :inventory_activity_logging) end)

    body = receive!(%{"lines" => [line(a, "1")]}, ctx)

    assert body["status"] == "posted"
    refute Repo.exists?(from(e in Entry, where: e.resource_uuid == ^body["document"]["id"]))
  end

  test "the stored lines carry the product's name, sku, unit and catalogue, as lines made in the admin do",
       %{a: a, ctx: ctx} do
    body = receive!(%{"lines" => [line(a, "2")]}, ctx)

    assert [stored] = Repo.get!(GoodsReceipt, body["document"]["id"]).lines

    assert %{
             "item_uuid" => item_uuid,
             "name" => name,
             "sku" => sku,
             "unit" => unit,
             "catalogue_uuid" => catalogue_uuid
           } = stored

    assert {item_uuid, name, sku, unit, catalogue_uuid} ==
             {a.uuid, a.name, a.sku, a.unit, a.catalogue_uuid}
  end

  test "from of a receipt line is derived from resulting_quantity, not from the unlocked previous_quantity" do
    item_uuid = Ecto.UUID.generate()

    # What a concurrent writer produces: previous_quantity was read before the
    # add and is stale, resulting_quantity is what the atomic add returned.
    doc = %{
      lines: [
        %{"item_uuid" => item_uuid, "previous_quantity" => "5", "resulting_quantity" => "9"}
      ]
    }

    line = %{item: %{uuid: item_uuid}, quantity: Decimal.new(3)}

    assert {from, to} = Write.line_change(:receipt, line, doc)
    assert {Decimal.to_string(from, :normal), Decimal.to_string(to, :normal)} == {"6", "9"}
  end

  test "a skipped retry writes no second Activity entry", %{a: a, ctx: ctx} do
    input = %{"external_ref" => "ACC-10", "lines" => [line(a, "1")]}
    receive!(input, ctx)
    receive!(input, ctx)

    count =
      Repo.aggregate(
        from(e in Entry, where: e.action == "warehouse.goods_receipt.posted"),
        :count
      )

    assert count == 1
  end
end
