defmodule PhoenixKitWarehouse.Web.InventoryFormLiveFingerprintTest do
  # The tab's base (spec §11.1): taken only with the buffer of lines, passed
  # to Save draft, to Conduct and to the warehouse change; a tab whose lines
  # are old is refused instead of writing over another tab's save. And who
  # gave a line's number (spec §10.4): a hand edit and a new line are "manual".
  use PhoenixKitWarehouse.LiveCase, async: false

  import PhoenixKitWarehouse.Test.InventoryAIFixtures

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryAI.Lines
  alias PhoenixKitWarehouse.StockLedger

  setup %{conn: conn} do
    admin = owner!()
    location = Ecto.UUID.generate()
    catalogue = catalogue!()
    hinge = item!(catalogue, %{name: "Hinge"})
    screw = item!(catalogue, %{name: "Screw"})
    stock!(hinge, location, "500")
    stock!(screw, location, "40")
    doc = draft!(location)

    %{conn: log_in(conn, admin), admin: admin, doc: doc, hinge: hinge, screw: screw}
  end

  defp items_path(doc), do: Routes.path("/admin/warehouse/inventory/#{doc.uuid}/items")
  defp files_path(doc), do: Routes.path("/admin/warehouse/inventory/#{doc.uuid}/files")

  defp index_of(doc, item),
    do:
      Enum.find_index(Inventories.get_document!(doc.uuid).lines, &(&1["item_uuid"] == item.uuid))

  defp set_counted(lv, index, value) do
    render_change(lv, "set_counted", %{"index" => to_string(index), "counted_quantity" => value})
  end

  defp line(doc, item),
    do: Enum.find(Inventories.get_document!(doc.uuid).lines, &(&1["item_uuid"] == item.uuid))

  defp stale_text, do: "The document was changed in another tab: reload the page."

  describe "two tabs" do
    test "A opened, B saved, A saves: A is refused and B's save stands", ctx do
      {:ok, a, _} = live(ctx.conn, items_path(ctx.doc))
      {:ok, b, _} = live(ctx.conn, items_path(ctx.doc))
      index = index_of(ctx.doc, ctx.hinge)

      set_counted(b, index, "480")
      render_click(b, "save_draft", %{})

      set_counted(a, index, "470")
      html = render_click(a, "save_draft", %{})

      assert html =~ stale_text()
      assert Lines.decimal(line(ctx.doc, ctx.hinge)["counted_quantity"]) |> Decimal.eq?(480)
    end

    test "A opened, B saved, A went to Files and back, A saves: still refused", ctx do
      {:ok, a, _} = live(ctx.conn, items_path(ctx.doc))
      {:ok, b, _} = live(ctx.conn, items_path(ctx.doc))
      index = index_of(ctx.doc, ctx.hinge)

      set_counted(b, index, "480")
      render_click(b, "save_draft", %{})

      render_patch(a, files_path(ctx.doc))
      render_patch(a, items_path(ctx.doc))
      set_counted(a, index, "470")

      assert render_click(a, "save_draft", %{}) =~ stale_text()
      assert Lines.decimal(line(ctx.doc, ctx.hinge)["counted_quantity"]) |> Decimal.eq?(480)
    end

    test "two saves in a row in one tab both pass", ctx do
      {:ok, a, _} = live(ctx.conn, items_path(ctx.doc))
      index = index_of(ctx.doc, ctx.hinge)

      set_counted(a, index, "480")
      refute render_click(a, "save_draft", %{}) =~ stale_text()

      set_counted(a, index, "470")
      refute render_click(a, "save_draft", %{}) =~ stale_text()

      assert Lines.decimal(line(ctx.doc, ctx.hinge)["counted_quantity"]) |> Decimal.eq?(470)
    end

    test "Conduct from a tab whose lines are old is refused, nothing is posted", ctx do
      {:ok, a, _} = live(ctx.conn, items_path(ctx.doc))
      {:ok, b, _} = live(ctx.conn, items_path(ctx.doc))

      set_counted(b, index_of(ctx.doc, ctx.hinge), "480")
      render_click(b, "save_draft", %{})

      assert render_click(a, "post", %{}) =~ stale_text()
      assert Inventories.get_document!(ctx.doc.uuid).status == "draft"
    end

    test "a Conduct that saved the lines and then failed leaves the tab's base the saved one",
         ctx do
      # A line of -5 cannot be posted: the save before the posting passes,
      # the posting fails.
      doc =
        draft!(ctx.doc.location_uuid, [
          %{"item_uuid" => ctx.hinge.uuid, "counted_quantity" => "-5"},
          %{"item_uuid" => ctx.screw.uuid, "counted_quantity" => "40"}
        ])

      {:ok, a, _} = live(ctx.conn, items_path(doc))
      set_counted(a, index_of(doc, ctx.screw), "480")

      html = render_click(a, "post", %{})
      assert html =~ "Failed to conduct stocktake"
      assert Inventories.get_document!(doc.uuid).status == "draft"
      assert Lines.decimal(line(doc, ctx.screw)["counted_quantity"]) |> Decimal.eq?(480)

      set_counted(a, index_of(doc, ctx.screw), "470")
      refute render_click(a, "save_draft", %{}) =~ stale_text()
      assert Lines.decimal(line(doc, ctx.screw)["counted_quantity"]) |> Decimal.eq?(470)
    end
  end

  describe "the warehouse change" do
    setup ctx do
      {:ok, type} =
        Locations.create_location_type(%{name: "WH #{System.unique_integer([:positive])}"})

      [site_a, site_b] =
        for name <- ["Site A", "Site B"] do
          {:ok, loc} = Locations.create_location(%{name: name, status: "active"})
          Locations.sync_location_types(loc.uuid, [type.uuid])
          loc
        end

      StockLedger.set_warehouse_location_type_uuid(type.uuid)
      stock!(ctx.hinge, site_a.uuid, "5")
      doc = draft!(site_a.uuid)
      %{site_b: site_b, doc: doc}
    end

    defp change_warehouse(lv, location) do
      lv
      |> element("form[phx-change='set_location']")
      |> render_change(%{"location_uuid" => location.uuid})

      render_click(lv, "confirm_location_change", %{})
    end

    test "from a tab whose lines are old is refused", ctx do
      path = Routes.path("/admin/warehouse/inventory/#{ctx.doc.uuid}")
      {:ok, a, _} = live(ctx.conn, path)
      {:ok, b, _} = live(ctx.conn, items_path(ctx.doc))

      set_counted(b, 0, "4")
      render_click(b, "save_draft", %{})

      assert change_warehouse(a, ctx.site_b) =~ stale_text()
      assert Inventories.get_document!(ctx.doc.uuid).location_uuid == ctx.doc.location_uuid
    end

    test "takes a new base with the new seed: a save after it passes", ctx do
      path = Routes.path("/admin/warehouse/inventory/#{ctx.doc.uuid}")
      {:ok, a, _} = live(ctx.conn, path)

      refute change_warehouse(a, ctx.site_b) =~ stale_text()
      assert Inventories.get_document!(ctx.doc.uuid).location_uuid == ctx.site_b.uuid
      refute render_click(a, "save_draft", %{}) =~ stale_text()
    end
  end

  describe "who gave the number" do
    test "a hand edit is the person's count: manual, the base, the photo parts in the history",
         ctx do
      parts = [%{"run_uuid" => "r1", "place" => "A", "qty" => "30"}]

      doc =
        draft!(ctx.doc.location_uuid, [
          %{
            "item_uuid" => ctx.hinge.uuid,
            "name" => "Hinge",
            "counted_quantity" => "30",
            "counted_by" => "ai",
            "base_qty" => "0",
            "ai_parts" => parts,
            "ai_basis" => "A: 30"
          }
        ])

      {:ok, lv, _} = live(ctx.conn, items_path(doc))
      set_counted(lv, 0, "32")
      render_click(lv, "save_draft", %{})

      hinge = line(doc, ctx.hinge)
      assert hinge["counted_by"] == "manual"
      assert hinge["base_source"] == "manual"
      assert Decimal.eq?(Lines.decimal(hinge["base_qty"]), 32)
      assert Decimal.eq?(Lines.decimal(hinge["counted_quantity"]), 32)
      refute Map.has_key?(hinge, "ai_parts")
      assert hinge["ai_parts_history"] == parts
    end

    test "typing the seeded number is a count too", ctx do
      {:ok, lv, _} = live(ctx.conn, items_path(ctx.doc))
      set_counted(lv, index_of(ctx.doc, ctx.hinge), "500")
      render_click(lv, "save_draft", %{})

      assert line(ctx.doc, ctx.hinge)["counted_by"] == "manual"
    end

    test "a line added by hand is manual", ctx do
      bolt = item!(catalogue!(), %{name: "Bolt"})
      {:ok, lv, _} = live(ctx.conn, items_path(ctx.doc))

      send(lv.pid, {:items_selected, %{picks: [%{uuid: bolt.uuid, qty: Decimal.new(3)}]}})
      render_click(lv, "save_draft", %{})

      assert line(ctx.doc, bolt)["counted_by"] == "manual"
      assert Decimal.eq?(Lines.decimal(line(ctx.doc, bolt)["counted_quantity"]), 3)
    end
  end
end
