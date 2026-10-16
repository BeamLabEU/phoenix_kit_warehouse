defmodule PhoenixKitWarehouse.API.IssueStockTest do
  @moduledoc """
  `warehouse.issue_stock`: a multi-line write-off. Every short line is
  reported at once and nothing is posted; the basis is an outside document or
  a shop order, and an `external_ref` makes a retry harmless in both cases.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKit.Activity.Entry
  alias PhoenixKitWarehouse.API.Write
  alias PhoenixKitWarehouse.DocRefs
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.Test.ApiOrderModule
  alias PhoenixKitWarehouse.Test.ApiOrders, as: Orders

  @registry_key {PhoenixKit, :registered_modules}

  setup do
    %{locations: [first, _second]} = warehouses!(2)
    catalogue = shop_catalogue!()
    user = user!()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_warehouse, :source_kinds)
      ApiOrderModule.reset()
    end)

    %{
      first: first,
      a: item!(catalogue),
      b: item!(catalogue),
      c: item!(catalogue),
      user: user,
      ctx: ctx(user)
    }
  end

  defp line(item, quantity), do: %{"ref" => %{"id" => item.uuid}, "quantity" => quantity}

  defp issue!(input, ctx) do
    assert {:ok, body} = Write.issue_stock(Map.put_new(input, "reason", "sale"), ctx)
    body
  end

  defp refused(input, ctx) do
    assert {:error, :validation_failed, _message, %{errors: errors, posted: false}} =
             Write.issue_stock(Map.put_new(input, "reason", "sale"), ctx)

    errors
  end

  defp counters do
    %{rows: [[last, called?]]} =
      Repo.query!(
        "SELECT last_value, is_called FROM phoenix_kit_warehouse_goods_issues_number_seq"
      )

    %{issues: Repo.aggregate(GoodsIssue, :count), sequence: {last, called?}}
  end

  defp register_orders(order_uuid \\ nil) do
    uuid = order_uuid || Ecto.UUID.generate()
    Orders.put(uuid, "Order #1001")
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [Orders.kind()])
    uuid
  end

  test "writes off several lines at once: stock drops, from/to are exact, the reason is stored",
       %{
         first: first,
         a: a,
         b: b,
         user: user,
         ctx: ctx
       } do
    seed!(a.uuid, "10", first.uuid)
    seed!(b.uuid, "5", first.uuid)

    body =
      issue!(
        %{
          "reason" => "damage",
          "lines" => [line(a, "4"), line(b, 5)],
          "note" => "broken in transit"
        },
        ctx
      )

    assert body["status"] == "posted"
    assert %{"type" => "goods_issue", "reason" => "damage", "number" => number} = body["document"]
    assert is_integer(number)

    assert [
             %{"action" => "updated", "from" => "10", "to" => "6"},
             %{"action" => "updated", "from" => "5", "to" => "0"}
           ] = body["results"]

    assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(6))
    assert Decimal.equal?(quantity(b.uuid, first.uuid), Decimal.new(0))

    issue = Repo.get!(GoodsIssue, body["document"]["id"])
    assert issue.reason == "damage" and issue.status == "posted"
    assert issue.created_by_uuid == user.uuid and issue.performed_by_uuid == user.uuid
  end

  describe "shortages" do
    test "every short line is reported and nothing is posted, no number burnt", %{
      first: first,
      a: a,
      b: b,
      c: c,
      ctx: ctx
    } do
      seed!(a.uuid, "1", first.uuid)
      seed!(b.uuid, "10", first.uuid)
      # c has no stock row at all.
      before = counters()
      stock_rows_before = Repo.aggregate(Stock, :count)

      assert {:error, :insufficient_stock, message, %{lines: lines, posted: false}} =
               Write.issue_stock(
                 %{"reason" => "sale", "lines" => [line(a, "3"), line(b, "2"), line(c, "1.5")]},
                 ctx
               )

      assert is_binary(message)

      assert Enum.sort_by(lines, & &1.id) ==
               Enum.sort_by(
                 [
                   %{
                     id: a.uuid,
                     ref: %{"id" => a.uuid},
                     sku: a.sku,
                     requested: "3",
                     available: "1"
                   },
                   %{
                     id: c.uuid,
                     ref: %{"id" => c.uuid},
                     sku: c.sku,
                     requested: "1.5",
                     available: "0"
                   }
                 ],
                 & &1.id
               )

      assert counters() == before
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(1))
      assert Decimal.equal?(quantity(b.uuid, first.uuid), Decimal.new(10))
      assert Repo.aggregate(Stock, :count) == stock_rows_before
    end

    test "issuing exactly what is there is allowed", %{first: first, a: a, ctx: ctx} do
      seed!(a.uuid, "2.5", first.uuid)
      body = issue!(%{"lines" => [line(a, "2.5")]}, ctx)
      assert [%{"from" => "2.5", "to" => "0"}] = body["results"]
    end
  end

  describe "the rest of the request" do
    test "reason is required and must be one of the four", %{a: a, ctx: ctx} do
      for bad <- [nil, "", "gift", 5] do
        input = %{"lines" => [line(a, "1")], "reason" => bad}

        assert {:error, :validation_failed, _message,
                %{errors: [%{path: "reason", code: "validation_failed"}]}} =
                 Write.issue_stock(input, ctx)
      end

      assert {:error, :validation_failed, _message, %{errors: [%{path: "reason"}]}} =
               Write.issue_stock(%{"lines" => [line(a, "1")]}, ctx)
    end

    test "a wrong reason is reported together with the errors of the lines", %{a: a, ctx: ctx} do
      input = %{
        "reason" => "gift",
        "lines" => [line(a, "1"), %{"ref" => %{"id" => Ecto.UUID.generate()}, "quantity" => "1"}]
      }

      assert {:error, :validation_failed, _message, %{errors: errors, posted: false}} =
               Write.issue_stock(input, ctx)

      assert Enum.sort(Enum.map(errors, & &1.path)) == ["lines[1].ref", "reason"]
    end

    test "unknown product, duplicate line and zero quantity are atomic refusals", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "5", first.uuid)
      before = counters()

      errors =
        refused(
          %{
            "lines" => [
              line(a, "1"),
              %{"ref" => %{"id" => Ecto.UUID.generate()}, "quantity" => "1"},
              line(a, "1"),
              %{"ref" => %{"id" => a.uuid}, "quantity" => 0}
            ]
          },
          ctx
        )

      assert Enum.sort(Enum.map(errors, &{&1.path, &1.code})) ==
               Enum.sort([
                 {"lines[1].ref", "not_found"},
                 {"lines[2]", "duplicate_line"},
                 {"lines[3].quantity", "validation_failed"},
                 {"lines[3]", "duplicate_line"}
               ])

      assert counters() == before
    end
  end

  describe "source: external" do
    test "is stored as external_ref; a retry is skipped and moves no stock", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "10", first.uuid)

      input = %{
        "source" => %{"kind" => "external", "ref" => " ACC-OUT-5 "},
        "lines" => [line(a, "4")]
      }

      posted = issue!(input, ctx)
      assert posted["document"]["external_ref"] == "ACC-OUT-5"

      again = issue!(input, ctx)
      assert again["status"] == "skipped"
      assert again["document"]["number"] == posted["document"]["number"]
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(6))
    end

    test "a retry still answers skipped after the stock it needed is gone", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "4", first.uuid)

      input = %{
        "source" => %{"kind" => "external", "ref" => "ACC-OUT-9"},
        "lines" => [line(a, "4")]
      }

      issue!(input, ctx)

      # The stock is 0 now: checking the lines afresh would say insufficient_stock.
      assert %{"status" => "skipped"} = issue!(input, ctx)
    end

    test "a reference reused for other lines is refused", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "10", first.uuid)
      source = %{"kind" => "external", "ref" => "ACC-OUT-10"}
      issue!(%{"source" => source, "lines" => [line(a, "4")]}, ctx)

      assert {:error, :validation_failed, _message,
              %{errors: [%{code: "external_ref_lines_differ"}], posted: false}} =
               Write.issue_stock(
                 %{"reason" => "sale", "source" => source, "lines" => [line(a, "7")]},
                 ctx
               )

      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(6))
    end

    test "shapes that are not a source are refused at source", %{a: a, ctx: ctx} do
      bad_sources = [
        %{"kind" => "external"},
        %{"kind" => "external", "ref" => "   "},
        %{"kind" => "external", "ref" => "X", "id" => Ecto.UUID.generate()},
        %{"kind" => "shop_order"},
        %{"kind" => "shop_order", "id" => "not-a-uuid"},
        %{"kind" => "shop_order", "id" => Ecto.UUID.generate(), "ref" => "X"},
        %{"kind" => "carrier_pigeon"},
        %{},
        "text"
      ]

      for source <- bad_sources do
        errors = refused(%{"source" => source, "lines" => [line(a, "1")]}, ctx)
        assert [%{path: path, code: "validation_failed"}] = errors, inspect(source)
        assert String.starts_with?(path, "source"), inspect(source)
      end
    end
  end

  describe "source: shop_order" do
    test "without the E-commerce kind registered the answer says which module is missing", %{
      a: a,
      ctx: ctx
    } do
      source = %{"kind" => "shop_order", "id" => Ecto.UUID.generate()}

      assert [%{path: "source", message: message}] =
               refused(%{"source" => source, "lines" => [line(a, "1")]}, ctx)

      assert message =~ "registers that kind"
      refute message =~ "disabled"
    end

    test "the 16 raw bytes of an order's UUID do not name that order", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "3", first.uuid)
      order = register_orders()
      raw = Ecto.UUID.dump!(order)
      assert byte_size(raw) == 16
      before = counters()

      for extra <- [%{}, %{"external_ref" => "RAW-ORDER-1"}] do
        input =
          Map.merge(extra, %{
            "source" => %{"kind" => "shop_order", "id" => raw},
            "lines" => [line(a, "1")]
          })

        assert [%{path: "source.id", code: "validation_failed"}] = refused(input, ctx)
      end

      assert counters() == before
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(3))
    end

    test "an unknown order is a validation_failed at source.id", %{a: a, ctx: ctx} do
      register_orders()
      source = %{"kind" => "shop_order", "id" => Ecto.UUID.generate()}

      assert [%{path: "source.id", code: "validation_failed"}] =
               refused(%{"source" => source, "lines" => [line(a, "1")]}, ctx)
    end

    test "a known order: the ref is stored under \"type\" and renders through DocRefs.refs_for/1",
         %{first: first, a: a, ctx: ctx} do
      seed!(a.uuid, "3", first.uuid)
      order = register_orders()

      body =
        issue!(
          %{
            "source" => %{"kind" => "shop_order", "id" => String.upcase(order)},
            "lines" => [line(a, "1")]
          },
          ctx
        )

      assert body["status"] == "posted"
      refute Map.has_key?(body, "effects")

      issue = Repo.get!(GoodsIssue, body["document"]["id"])
      assert issue.source_refs == [%{"type" => "shop_order", "uuid" => order}]
      assert issue.external_ref == nil

      assert [
               %{
                 label: "Order #1001",
                 uuid: ^order,
                 kind: "shop_order",
                 path: "/admin/orders" <> _
               }
             ] =
               DocRefs.refs_for(issue.source_refs)
    end

    test "while the module that declares the kind is disabled the answer says so; enabled, it works",
         %{first: first, a: a, ctx: ctx} do
      seed!(a.uuid, "3", first.uuid)
      order = Ecto.UUID.generate()
      Orders.put(order, "Order #1002")

      previous = :persistent_term.get(@registry_key, :unset)
      :persistent_term.put(@registry_key, [ApiOrderModule])

      on_exit(fn ->
        case previous do
          :unset -> :persistent_term.erase(@registry_key)
          modules -> :persistent_term.put(@registry_key, modules)
        end
      end)

      input = %{"source" => %{"kind" => "shop_order", "id" => order}, "lines" => [line(a, "1")]}

      ApiOrderModule.enable(false)
      assert [%{path: "source", message: message}] = refused(input, ctx)
      assert message =~ "disabled"
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(3))

      ApiOrderModule.enable(true)
      assert %{"status" => "posted"} = issue!(input, ctx)
    end
  end

  describe "external_ref beside the source" do
    test "with a shop order it is stored on the document; a retry is skipped and moves no stock",
         %{first: first, a: a, ctx: ctx} do
      seed!(a.uuid, "10", first.uuid)
      order = register_orders()

      input = %{
        "external_ref" => " SHOP-OUT-1 ",
        "source" => %{"kind" => "shop_order", "id" => order},
        "lines" => [line(a, "4")]
      }

      posted = issue!(input, ctx)
      assert posted["document"]["external_ref"] == "SHOP-OUT-1"

      issue = Repo.get!(GoodsIssue, posted["document"]["id"])
      assert issue.external_ref == "SHOP-OUT-1"
      assert issue.source_refs == [%{"type" => "shop_order", "uuid" => order}]

      before = counters()
      again = issue!(input, ctx)
      assert again["status"] == "skipped"
      assert again["document"]["number"] == posted["document"]["number"]
      assert counters() == before
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(6))
    end

    test "without any source it is stored too, and a retry is skipped", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "10", first.uuid)
      input = %{"external_ref" => "LOOSE-1", "lines" => [line(a, "3")]}

      posted = issue!(input, ctx)
      assert posted["document"]["external_ref"] == "LOOSE-1"

      assert %{"status" => "skipped"} = issue!(input, ctx)
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(7))
    end

    test "a retry is answered from the posted document even after the product was trashed", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "10", first.uuid)
      input = %{"external_ref" => "LOOSE-2", "lines" => [line(a, "3")]}
      posted = issue!(input, ctx)

      {:ok, _item} = PhoenixKitCatalogue.Catalogue.trash_item(a)

      assert {:ok, again, [effect]} = Write.issue_stock(Map.put(input, "reason", "sale"), ctx)
      assert again["status"] == "skipped"
      assert again["document"]["number"] == posted["document"]["number"]
      assert effect["code"] == "external_ref_lines_unverified"
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(7))
    end

    test "a retry with a shop order is answered from the document after the product was trashed and the order kind withdrawn",
         %{first: first, a: a, ctx: ctx} do
      seed!(a.uuid, "10", first.uuid)
      order = register_orders()

      input = %{
        "reason" => "sale",
        "external_ref" => "SHOP-OUT-2",
        "source" => %{"kind" => "shop_order", "id" => order},
        "lines" => [line(a, "3")]
      }

      posted = issue!(input, ctx)
      {:ok, _item} = PhoenixKitCatalogue.Catalogue.trash_item(a)
      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [])

      assert {:ok, again, [effect]} = Write.issue_stock(input, ctx)
      assert again["status"] == "skipped"
      assert again["document"]["number"] == posted["document"]["number"]
      assert effect["code"] == "external_ref_lines_unverified"
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(7))
    end

    test "a retry with an external source is answered from the document after the product was trashed",
         %{first: first, a: a, ctx: ctx} do
      seed!(a.uuid, "10", first.uuid)

      input = %{
        "source" => %{"kind" => "external", "ref" => "ACC-OUT-11"},
        "lines" => [line(a, "3")]
      }

      posted = issue!(input, ctx)

      {:ok, _item} = PhoenixKitCatalogue.Catalogue.trash_item(a)

      assert {:ok, again, [effect]} = Write.issue_stock(Map.put(input, "reason", "sale"), ctx)
      assert again["status"] == "skipped"
      assert again["document"]["number"] == posted["document"]["number"]
      assert effect["code"] == "external_ref_lines_unverified"
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(7))
    end

    test "a blank or non-string external_ref is refused at external_ref", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "10", first.uuid)

      for bad <- ["   ", "", 5] do
        assert [%{path: "external_ref", code: "validation_failed"}] =
                 refused(%{"external_ref" => bad, "lines" => [line(a, "1")]}, ctx)
      end

      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(10))
    end

    test "together with an external source it is refused: the source's ref is the reference", %{
      first: first,
      a: a,
      ctx: ctx
    } do
      seed!(a.uuid, "10", first.uuid)

      input = %{
        "external_ref" => "ONE",
        "source" => %{"kind" => "external", "ref" => "TWO"},
        "lines" => [line(a, "1")]
      }

      assert [%{path: "external_ref", code: "validation_failed"}] = refused(input, ctx)
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(10))
    end
  end

  test "the Activity entry names the reason, the order, the reference and the warehouse", %{
    first: first,
    a: a,
    ctx: ctx
  } do
    seed!(a.uuid, "3", first.uuid)
    order = register_orders()

    body =
      issue!(
        %{
          "reason" => "sale",
          "external_ref" => "ISSUE-ACT-1",
          "source" => %{"kind" => "shop_order", "id" => order},
          "lines" => [line(a, "1")]
        },
        ctx
      )

    entry =
      Repo.one!(
        from(e in Entry,
          where:
            e.action == "warehouse.goods_issue.posted" and
              e.resource_uuid == ^body["document"]["id"]
        )
      )

    assert %{
             "via" => "api",
             "tool" => "warehouse.issue_stock",
             "reason" => "sale",
             "order_uuid" => ^order,
             "external_ref" => "ISSUE-ACT-1",
             "location_uuid" => location_uuid
           } = entry.metadata

    assert location_uuid == first.uuid
  end
end
