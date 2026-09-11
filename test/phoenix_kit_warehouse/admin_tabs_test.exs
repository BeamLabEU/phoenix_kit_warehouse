defmodule PhoenixKitWarehouse.AdminTabsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins the sidebar wiring in `PhoenixKitWarehouse.admin_tabs/0`.

  Two of these properties are invisible until someone opens the page and
  notices the menu pointing at the wrong row, which is exactly the kind of
  thing that regresses quietly:

  * the "In stock" subtab must NOT declare a `live_view` — the section root
    already declares that route, and a second declaration at the same path
    compiles to a dead duplicate;
  * the Stocktakes tab has to match BOTH `/warehouse/inventories` (the list)
    and `/warehouse/inventory/:uuid` (a document), which differ in their first
    segment, so the default `:prefix` match cannot cover them.

  `Tab.matches_path?/2` is pure, and `admin_tabs/0` is a plain list of structs,
  so none of this needs a database or a running endpoint. The paths below are
  written the way the tab registry stores them (absolute, `/admin`-prefixed);
  `Tab.normalize_path/1` strips a locale prefix before matching, which the
  locale case covers.
  """

  alias PhoenixKit.Dashboard.Tab

  defp tab(id) do
    PhoenixKitWarehouse.admin_tabs()
    |> Enum.find(&(&1.id == id))
    |> case do
      nil -> flunk("no tab #{inspect(id)} in admin_tabs/0")
      tab -> tab
    end
  end

  # The registry rewrites a module tab's relative `path` into an absolute,
  # admin-prefixed one. Regex matches are written against that final shape, so
  # compare against it here rather than against the raw struct field.
  defp registered(id) do
    %{tab(id) | path: "/admin/" <> tab(id).path}
  end

  describe "the In stock subtab" do
    test "declares no live_view of its own" do
      assert tab(:warehouse_stock).live_view == nil,
             "the root tab already declares this route; a second declaration is dead code"
    end

    test "sits on the section root's own path, under the root as parent" do
      assert tab(:warehouse_stock).path == tab(:warehouse).path
      assert tab(:warehouse_stock).parent == :warehouse
      assert tab(:warehouse_stock).visible == true
    end

    test "lights only on the stock list itself" do
      stock = registered(:warehouse_stock)

      assert Tab.matches_path?(stock, "/admin/warehouse")
      refute Tab.matches_path?(stock, "/admin/warehouse/inventories")
      refute Tab.matches_path?(stock, "/admin/warehouse/transfers")
    end
  end

  describe "the Stocktakes subtab" do
    test "stays lit on a stocktake document, not just on the list" do
      stocktakes = registered(:warehouse_inventories)

      for path <- [
            "/admin/warehouse/inventories",
            "/admin/warehouse/inventory/019d0000-0000-7000-8000-000000000000",
            "/admin/warehouse/inventory/019d0000-0000-7000-8000-000000000000/items",
            "/admin/warehouse/inventory/019d0000-0000-7000-8000-000000000000/files",
            "/admin/warehouse/inventory/new"
          ] do
        assert Tab.matches_path?(stocktakes, path), "expected Stocktakes to match #{path}"
      end
    end

    test "survives a locale prefix" do
      stocktakes = registered(:warehouse_inventories)

      assert Tab.matches_path?(stocktakes, "/ru/admin/warehouse/inventories")
      assert Tab.matches_path?(stocktakes, "/et/admin/warehouse/inventory/abc/items")
    end

    test "does not leak onto the section root or a sibling" do
      stocktakes = registered(:warehouse_inventories)

      refute Tab.matches_path?(stocktakes, "/admin/warehouse")
      refute Tab.matches_path?(stocktakes, "/admin/warehouse/transfers")
      refute Tab.matches_path?(stocktakes, "/admin/warehouse/internal-orders")
      # The anchor has to reject a longer word starting with the same stem.
      refute Tab.matches_path?(stocktakes, "/admin/warehouse/inventoryreport")
    end
  end

  describe "sidebar order" do
    test "matches the order of the tab bar above the page" do
      # WarehouseHeader renders the tabs in this order; the sidebar is sorted by
      # :priority, and the two had drifted apart for transfers/receipts/issues.
      expected = [
        :warehouse_stock,
        :warehouse_inventories,
        :warehouse_internal_orders,
        :warehouse_supplier_orders,
        :warehouse_transfers,
        :warehouse_goods_receipts,
        :warehouse_goods_issues,
        :warehouse_turnover
      ]

      actual =
        PhoenixKitWarehouse.admin_tabs()
        |> Enum.filter(&(&1.parent == :warehouse and &1.visible == true))
        |> Enum.sort_by(& &1.priority)
        |> Enum.map(& &1.id)

      assert actual == expected
    end
  end
end
