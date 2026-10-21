defmodule PhoenixKitWarehouse.LineExplanationTest do
  @moduledoc false
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.LineExplanation
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Test.FakeOrderSources

  @location "00000000-0000-0000-0000-000000000001"

  setup do
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
      FakeOrderSources.order_kind(),
      FakeOrderSources.sub_order_kind()
    ])

    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :source_kinds) end)
    :ok
  end

  defp user_uuid do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "expl-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Ex",
        "last_name" => "Pl"
      })

    user.uuid
  end

  defp admin_conn(conn) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "expl-admin-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Admin",
        "last_name" => "User"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.promote_to_admin(user)
    token = Auth.generate_user_session_token(Auth.get_user!(user.uuid))
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  # An item that resolves to exactly one supplier (through its manufacturer).
  defp supplied_item! do
    {:ok, mfr} = Catalogue.create_manufacturer(%{name: "M #{System.unique_integer([:positive])}"})

    {:ok, supplier} =
      Catalogue.create_supplier(%{
        name: "S #{System.unique_integer([:positive])}",
        status: "active"
      })

    Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
    {:ok, cat} = Catalogue.create_catalogue(%{name: "C #{System.unique_integer([:positive])}"})

    {:ok, item} =
      Catalogue.create_item(%{
        name: "Item #{System.unique_integer([:positive])}",
        catalogue_uuid: cat.uuid,
        manufacturer_uuid: mfr.uuid,
        status: "active"
      })

    {item, supplier}
  end

  defp line(item, qty, extra \\ %{}) do
    Map.merge(
      %{
        "item_uuid" => item.uuid,
        "name" => item.name,
        "catalogue_uuid" => item.catalogue_uuid,
        "required_quantity" => qty
      },
      extra
    )
  end

  defp posted_io!(lines, actor) do
    {:ok, io} = InternalOrders.create_internal_order(%{location_uuid: @location, lines: lines})
    {:ok, io} = InternalOrders.post_internal_order(io, actor)
    io
  end

  defp draft_so!(supplier) do
    {:ok, so} =
      SupplierOrders.create_supplier_order(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @location
      })

    so
  end

  describe "LineExplanation" do
    test "merge joins paragraphs without repeating one" do
      assert LineExplanation.merge("A\n\nB", "B\n\nC") == "A\n\nB\n\nC"
      assert LineExplanation.merge("A", "A") == "A"
      assert LineExplanation.merge(nil, "A") == "A"
      assert LineExplanation.merge("  ", nil) == nil
    end

    test "get ignores blank and non-string values" do
      assert LineExplanation.get(%{"explanation" => " "}) == nil
      assert LineExplanation.get(%{"explanation" => 5}) == nil
      assert LineExplanation.get(%{"explanation" => "x"}) == "x"
      refute LineExplanation.any?([%{}, %{"explanation" => ""}])
      assert LineExplanation.any?([%{}, %{"explanation" => "x"}])
    end
  end

  describe "merge_into/2" do
    test "leaves the target untouched when the source has no explanation" do
      target = %{"explanation" => "A\n\nA"}
      assert LineExplanation.merge_into(target, %{}) == target
      assert LineExplanation.merge_into(target, %{"explanation" => " "}) == target
      assert LineExplanation.merge_into(%{}, %{}) == %{}
    end
  end

  describe "carry into supplier orders" do
    test "generate_from_internal_order carries the explanation to the supplier order" do
      actor = user_uuid()
      {item, _supplier} = supplied_item!()
      io = posted_io!([line(item, "5", %{"explanation" => "Needed for paint job"})], actor)

      {:ok, %{supplier_orders: [so]}} = SupplierOrders.generate_from_internal_order(io, actor)

      assert [%{"explanation" => "Needed for paint job"}] = so.lines
    end

    test "a line without explanation gets no key" do
      actor = user_uuid()
      {item, _} = supplied_item!()
      io = posted_io!([line(item, "5")], actor)

      {:ok, %{supplier_orders: [so]}} = SupplierOrders.generate_from_internal_order(io, actor)

      refute Map.has_key?(hd(so.lines), "explanation")
    end

    test "the explanation is carried into the unassigned lines too" do
      actor = user_uuid()
      {:ok, cat} = Catalogue.create_catalogue(%{name: "C #{System.unique_integer([:positive])}"})

      {:ok, item} =
        Catalogue.create_item(%{name: "Lone", catalogue_uuid: cat.uuid, status: "active"})

      io = posted_io!([line(item, "2", %{"explanation" => "why"})], actor)

      {:ok, %{unassigned_lines: [unassigned]}} =
        SupplierOrders.generate_from_internal_order(io, actor)

      assert unassigned["explanation"] == "why"
    end

    test "import_from_internal_orders carries it and merges equal texts once" do
      actor = user_uuid()
      {item, supplier} = supplied_item!()
      io1 = posted_io!([line(item, "4", %{"explanation" => "Shared\n\nFrom one"})], actor)
      io2 = posted_io!([line(item, "6", %{"explanation" => "Shared\n\nFrom two"})], actor)

      {:ok, so} =
        SupplierOrders.import_from_internal_orders(
          draft_so!(supplier),
          [io1.uuid, io2.uuid],
          actor
        )

      assert [%{"explanation" => text}] = so.lines
      assert text == "Shared\n\nFrom one\n\nFrom two"
    end

    test "importing into an existing line appends a different explanation" do
      actor = user_uuid()
      {item, supplier} = supplied_item!()
      io1 = posted_io!([line(item, "4", %{"explanation" => "First"})], actor)
      io2 = posted_io!([line(item, "6", %{"explanation" => "Second"})], actor)

      {:ok, so} =
        SupplierOrders.import_from_internal_orders(draft_so!(supplier), [io1.uuid], actor)

      {:ok, so} = SupplierOrders.import_from_internal_orders(so, [io2.uuid], actor)

      assert [%{"explanation" => "First\n\nSecond"}] = so.lines
    end

    test "importing into an existing line merges with its explanation" do
      actor = user_uuid()
      {item, supplier} = supplied_item!()
      io1 = posted_io!([line(item, "4", %{"explanation" => "First"})], actor)
      io2 = posted_io!([line(item, "6", %{"explanation" => "First"})], actor)

      {:ok, so} =
        SupplierOrders.import_from_internal_orders(draft_so!(supplier), [io1.uuid], actor)

      {:ok, so} = SupplierOrders.import_from_internal_orders(so, [io2.uuid], actor)

      assert [%{"explanation" => "First"}] = so.lines
    end
  end

  describe "import_from_sources" do
    test "carries the explanation to a new line and merges into an existing one" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()

      mk = fn text ->
        FakeOrderSources.put_sub_order(%{
          uuid: Ecto.UUID.generate(),
          label: "so",
          lines: [
            %{
              "item_uuid" => item_uuid,
              "name" => "Paint",
              "required_quantity" => "3",
              "explanation" => text
            }
          ]
        })
      end

      a = mk.("Because A")
      b = mk.("Because A\n\nBecause B")

      {:ok, io} = InternalOrders.create_internal_order(%{location_uuid: @location})

      {:ok, io} =
        InternalOrders.import_from_sources(
          io,
          [%{"type" => "sub_order", "uuid" => a.uuid}],
          actor
        )

      assert [%{"explanation" => "Because A"}] = io.lines

      {:ok, io} =
        InternalOrders.import_from_sources(
          io,
          [%{"type" => "sub_order", "uuid" => b.uuid}],
          actor
        )

      assert [%{"required_quantity" => "6", "explanation" => "Because A\n\nBecause B"}] = io.lines
    end
  end

  describe "forms" do
    test "the item name from the catalogue wins over the name stored on the line", %{conn: conn} do
      conn = admin_conn(conn)
      {item, _} = supplied_item!()

      {:ok, io} =
        InternalOrders.create_internal_order(%{
          location_uuid: @location,
          lines: [line(item, "3", %{"name" => "Stale name", "explanation" => "why"})]
        })

      {:ok, lv, _} = live(conn, Routes.path("/admin/warehouse/internal-orders/#{io.uuid}/items"))
      assert has_element?(lv, "#internal-order-explanations", item.name)
      refute has_element?(lv, "#internal-order-explanations", "Stale name")
    end

    test "internal order Items tab shows the block only with explanations", %{conn: conn} do
      conn = admin_conn(conn)
      item_uuid = Ecto.UUID.generate()

      {:ok, with_expl} =
        InternalOrders.create_internal_order(%{
          location_uuid: @location,
          lines: [
            %{
              "item_uuid" => item_uuid,
              "name" => "Paint",
              "required_quantity" => "3",
              "explanation" => "Spec of the table"
            }
          ]
        })

      {:ok, without} =
        InternalOrders.create_internal_order(%{
          location_uuid: @location,
          lines: [%{"item_uuid" => item_uuid, "name" => "Paint", "required_quantity" => "3"}]
        })

      path = &Routes.path("/admin/warehouse/internal-orders/#{&1}/items")

      {:ok, lv, _} = live(conn, path.(with_expl.uuid))
      assert has_element?(lv, "#internal-order-explanations", "Spec of the table")
      assert has_element?(lv, "#internal-order-explanations", "Paint")
      refute has_element?(lv, "#internal-order-explanations-quantity-logic")

      {:ok, lv, _} = live(conn, path.(without.uuid))
      refute has_element?(lv, "#internal-order-explanations")
    end

    test "supplier order Lines tab shows the block and the quantity logic only with explanations",
         %{conn: conn} do
      conn = admin_conn(conn)
      {item, supplier} = supplied_item!()
      base = draft_so!(supplier)

      base_line = %{
        "item_uuid" => item.uuid,
        "name" => "Widget",
        "unit" => "piece",
        "required_quantity" => "5",
        "on_hand_quantity" => "0",
        "shortfall_quantity" => "5",
        "ordered_quantity" => "5"
      }

      {:ok, with_expl} =
        SupplierOrders.update_draft(base, %{
          lines: [Map.put(base_line, "explanation", "Because of the table")]
        })

      path = &Routes.path("/admin/warehouse/supplier-orders/#{&1}/lines")

      {:ok, lv, _} = live(conn, path.(with_expl.uuid))
      assert has_element?(lv, "#supplier-order-explanations", "Because of the table")
      assert has_element?(lv, "#supplier-order-explanations-quantity-logic")

      {:ok, without} = SupplierOrders.update_draft(base, %{lines: [base_line]})
      {:ok, lv, _} = live(conn, path.(without.uuid))
      refute has_element?(lv, "#supplier-order-explanations")
      refute has_element?(lv, "#supplier-order-explanations-quantity-logic")
    end
  end
end
