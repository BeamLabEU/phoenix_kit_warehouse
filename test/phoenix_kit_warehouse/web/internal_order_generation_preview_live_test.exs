defmodule PhoenixKitWarehouse.Web.InternalOrderGenerationPreviewLiveTest do
  @moduledoc """
  The window of "Generate supplier orders" on a posted internal order: the
  blocks and the reasons, the warning about the existing draft and "now ->
  after", manual and bulk choices, the summary, Cancel, and Generate writing
  exactly what the window shows (`SupplierOrders.assemble/2` of the same plan
  and choices) - or showing the plan again when it went stale.
  """

  use PhoenixKitWarehouse.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.ItemSupplierInfo
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Test.Repo

  @location "00000000-0000-0000-0000-000000000001"
  @form "#io-generation-preview-form"

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp unique, do: System.unique_integer([:positive])

  defp admin! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "io-preview-#{unique()}@example.com",
        "password" => "password123456789",
        "first_name" => "Preview",
        "last_name" => "Keeper"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.promote_to_admin(user)
    Auth.get_user!(user.uuid)
  end

  defp log_in(conn, user) do
    token = Auth.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  defp supplier!(name \\ nil) do
    {:ok, supplier} =
      Catalogue.create_supplier(%{name: name || "Supplier #{unique()}", status: "active"})

    supplier
  end

  defp manufacturer!(suppliers) do
    {:ok, mfr} = Catalogue.create_manufacturer(%{name: "Mfr #{unique()}", status: "active"})
    Enum.each(suppliers, &Catalogue.link_manufacturer_supplier(mfr.uuid, &1.uuid))
    mfr
  end

  defp item!(attrs \\ %{}) do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Cat #{unique()}", status: "active"})

    {:ok, item} =
      Catalogue.create_item(
        Map.merge(
          %{
            name: "Item #{unique()}",
            sku: "SKU-#{unique()}",
            catalogue_uuid: catalogue.uuid,
            status: "active"
          },
          attrs
        )
      )

    item
  end

  # An item supplied only through its manufacturer's `suppliers`.
  defp item_of!(suppliers), do: item!(%{manufacturer_uuid: manufacturer!(suppliers).uuid})

  defp info!(item, supplier, primary?) do
    {:ok, info} =
      Catalogue.create_supplier_info(%{
        item_uuid: item.uuid,
        supplier_uuid: supplier.uuid,
        supplier_source: "local"
      })

    Repo.update_all(from(i in ItemSupplierInfo, where: i.uuid == ^info.uuid),
      set: [is_primary: primary?]
    )
  end

  defp io_line(item, qty, extra \\ %{})

  defp io_line(%{uuid: uuid} = item, qty, extra) do
    Map.merge(
      %{
        "item_uuid" => uuid,
        "name" => item.name,
        "sku" => item.sku,
        "unit" => "piece",
        "catalogue_uuid" => item.catalogue_uuid,
        "required_quantity" => qty
      },
      extra
    )
  end

  defp gone_line(qty),
    do: %{"item_uuid" => Ecto.UUID.generate(), "name" => "Gone", "required_quantity" => qty}

  defp posted_io!(lines) do
    {:ok, io} = InternalOrders.create_internal_order(%{location_uuid: @location, lines: lines})
    {:ok, posted} = InternalOrders.post_internal_order(io, nil)
    posted
  end

  defp stock!(item, qty) do
    {:ok, _} = StockLedger.upsert_quantity(item.uuid, qty, location_uuid: @location)
  end

  defp draft_of!(io, supplier, lines) do
    {:ok, so} =
      SupplierOrders.create_supplier_order(%{
        location_uuid: @location,
        internal_order_uuid: io.uuid,
        supplier_uuid: supplier.uuid,
        lines: lines
      })

    so
  end

  defp so_line(item, qty) do
    %{
      "item_uuid" => item.uuid,
      "name" => item.name,
      "ordered_quantity" => qty,
      "shortfall_quantity" => qty
    }
  end

  defp form_path(io), do: Routes.path("/admin/warehouse/internal-orders/#{io.uuid}")

  defp open!(conn, io) do
    {:ok, lv, _html} = live(conn, form_path(io))
    lv |> element("#io-generate-supplier-orders") |> render_click()
    assert has_element?(lv, "#io-generation-preview")
    lv
  end

  defp plan!(io) do
    {:ok, plan} = SupplierOrders.plan_from_internal_order(io.uuid)
    plan
  end

  defp line_of(plan, item), do: Enum.find(plan.lines, &(&1.item_uuid == item.uuid))

  defp row(plan, item), do: "#io-preview-line-#{line_of(plan, item).index}"

  defp change!(lv, params), do: lv |> element(@form) |> render_change(params)

  defp submit!(lv), do: lv |> element(@form) |> render_submit()

  defp all_orders, do: Repo.all(from(o in SupplierOrder, order_by: [asc: o.number]))

  defp orders_of(io) do
    from(o in SupplierOrder,
      where: o.internal_order_uuid == ^io.uuid and is_nil(o.deleted_at),
      order_by: [asc: o.number]
    )
    |> Repo.all()
  end

  defp snapshot, do: Enum.map(all_orders(), &{&1.uuid, &1.lines, &1.source_refs, &1.updated_at})

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp quantities(lines) do
    Map.new(lines, fn line ->
      {line["item_uuid"], StockLedger.format_quantity(line["ordered_quantity"])}
    end)
  end

  setup %{conn: conn} do
    Repo.delete_all(InternalOrder)
    {:ok, conn: log_in(conn, admin!())}
  end

  # ---------------------------------------------------------------------------
  # Opening and closing
  # ---------------------------------------------------------------------------

  describe "the button" do
    test "opens the window and writes nothing; Cancel closes it and writes nothing",
         %{conn: conn} do
      s = supplier!()
      io = posted_io!([io_line(item_of!([s]), "5")])
      before = snapshot()

      {:ok, lv, _html} = live(conn, form_path(io))
      refute has_element?(lv, "#io-generate-supplier-orders[data-confirm]")
      refute has_element?(lv, "#io-generation-preview")

      lv |> element("#io-generate-supplier-orders") |> render_click()

      assert has_element?(lv, "#io-generation-preview")
      assert has_element?(lv, "#io-preview-group-#{s.uuid}")
      assert snapshot() == before

      lv |> element("#io-preview-cancel") |> render_click()

      refute has_element?(lv, "#io-generation-preview")
      assert snapshot() == before
    end

    test "the window's events after Cancel do nothing", %{conn: conn} do
      s = supplier!()
      io = posted_io!([io_line(item_of!([s]), "5")])
      lv = open!(conn, io)
      before = snapshot()

      lv |> element("#io-preview-cancel") |> render_click()
      render_click(lv, "preview_confirm", %{})

      refute has_element?(lv, "#io-generation-preview")
      assert snapshot() == before
    end
  end

  # ---------------------------------------------------------------------------
  # The blocks
  # ---------------------------------------------------------------------------

  describe "the blocks and their reasons" do
    test "suppliers, the lines to choose and the lines with nothing to order", %{conn: conn} do
      [s_primary, s_link, s_mfr, s_a, s_b] = for _ <- 1..5, do: supplier!()

      primary = item_of!([s_mfr])
      info!(primary, s_primary, true)
      linked = item!()
      info!(linked, s_link, false)
      by_mfr = item_of!([s_mfr])
      ambiguous = item_of!([s_a, s_b])
      none = item!()
      covered = item_of!([s_mfr])
      stock!(covered, "20")

      io =
        posted_io!([
          io_line(primary, "1"),
          io_line(linked, "2"),
          io_line(by_mfr, "3"),
          io_line(ambiguous, "4"),
          io_line(none, "5"),
          io_line(covered, "6"),
          gone_line("7")
        ])

      plan = plan!(io)
      lv = open!(conn, io)

      group = &"#io-preview-group-#{&1.uuid}"

      assert has_element?(lv, "#{group.(s_primary)} #{row(plan, primary)}")
      assert has_element?(lv, "#{group.(s_primary)}-new")
      assert has_element?(lv, row(plan, primary), "Primary supplier of the item")
      assert has_element?(lv, "#{group.(s_link)} #{row(plan, linked)}")
      assert has_element?(lv, row(plan, linked), "The only supplier of the item")
      assert has_element?(lv, "#{group.(s_mfr)} #{row(plan, by_mfr)}")
      assert has_element?(lv, row(plan, by_mfr), "The only supplier of the manufacturer")

      assert has_element?(lv, "#io-preview-choose #{row(plan, ambiguous)}")
      assert has_element?(lv, row(plan, ambiguous), "Several suppliers")
      assert has_element?(lv, "#io-preview-choose #{row(plan, none)}")
      assert has_element?(lv, row(plan, none), "No supplier found")

      assert has_element?(lv, "#io-preview-not-ordered #{row(plan, covered)}")
      assert has_element?(lv, row(plan, covered), "Covered by stock")
      gone = Enum.find(plan.lines, &(&1.reason == :no_item))
      assert has_element?(lv, "#io-preview-not-ordered #io-preview-line-#{gone.index}")
      assert has_element?(lv, "#io-preview-line-#{gone.index}", "not in the catalogue")

      # Candidates of the item first, with their source, then all suppliers.
      assert has_element?(
               lv,
               "#io-preview-choice-#{line_of(plan, ambiguous).index} optgroup option[value='#{s_a.uuid}']",
               "manufacturer's supplier"
             )

      assert has_element?(
               lv,
               "#io-preview-choice-#{line_of(plan, ambiguous).index} option[value='skip'][selected]"
             )

      assert has_element?(
               lv,
               "#io-preview-summary",
               "New orders: 3, appended: 0 (lines: 3); not ordered: 3"
             )
    end

    test "a line's columns, its comment and what is already ordered under Why", %{conn: conn} do
      s = supplier!()
      item = item_of!([s])
      stock!(item, "2")

      io =
        posted_io!([io_line(item, "10", %{"explanation" => "Comment of the line"})])

      plan = plan!(io)
      line = line_of(plan, item)
      lv = open!(conn, io)

      assert has_element?(lv, row(plan, item), item.sku)
      assert has_element?(lv, "#io-preview-why-#{line.index}", "Comment of the line")
      assert has_element?(lv, row(plan, item) <> " td.font-semibold", "8")
    end

    test "a draft without a supplier is named as such where it counts as ordered",
         %{conn: conn} do
      s = supplier!()
      partly = item_of!([s])
      covered = item_of!([s])
      io = posted_io!([io_line(partly, "5"), io_line(covered, "3")])

      {:ok, no_supplier} =
        SupplierOrders.create_supplier_order(%{
          location_uuid: @location,
          internal_order_uuid: io.uuid,
          lines: [so_line(partly, "3"), so_line(covered, "3")]
        })

      plan = plan!(io)
      lv = open!(conn, io)

      assert has_element?(
               lv,
               "#io-preview-why-#{line_of(plan, partly).index}",
               "Already ordered in draft #SO-#{no_supplier.number} without supplier: 3"
             )

      assert has_element?(
               lv,
               "#io-preview-reason-#{line_of(plan, covered).index}",
               "Already ordered in #SO-#{no_supplier.number} (draft without supplier)"
             )
    end

    test "the names of a draft without a supplier are translated in every bundled language" do
      for {locale, why, label} <- [
            {"ru", "Уже заказано в черновике #SO-7 без поставщика: 3",
             "#SO-7 (черновик без поставщика)"},
            {"et", "Juba tellitud tarnijata mustandis #SO-7: 3", "#SO-7 (tarnijata mustand)"},
            {"uk", "Уже замовлено в чернетці #SO-7 без постачальника: 3",
             "#SO-7 (чернетка без постачальника)"}
          ] do
        Gettext.with_locale(PhoenixKitWarehouse.Gettext, locale, fn ->
          assert Gettext.dgettext(
                   PhoenixKitWarehouse.Gettext,
                   "default",
                   "Already ordered in draft %{number} without supplier: %{quantity}",
                   number: "#SO-7",
                   quantity: "3"
                 ) == why

          assert Gettext.dgettext(
                   PhoenixKitWarehouse.Gettext,
                   "default",
                   "%{number} (draft without supplier)",
                   number: "#SO-7"
                 ) == label
        end)
      end
    end

    test "nothing to order: Generate is disabled", %{conn: conn} do
      s = supplier!()
      item = item_of!([s])
      stock!(item, "50")
      io = posted_io!([io_line(item, "5")])

      lv = open!(conn, io)

      assert has_element?(lv, "#io-preview-submit[disabled]")
      assert has_element?(lv, "#io-preview-submit[phx-disable-with]")
    end
  end

  # ---------------------------------------------------------------------------
  # The existing draft
  # ---------------------------------------------------------------------------

  describe "the draft of the supplier" do
    test "the group warns that what is missing goes into the draft, a row shows now -> after",
         %{conn: conn} do
      s = supplier!()
      other = supplier!()
      a = item_of!([s])
      b = item_of!([s])
      c = item_of!([other])
      io = posted_io!([io_line(a, "10"), io_line(b, "3"), io_line(c, "2")])
      draft = draft_of!(io, s, [so_line(a, "4")])

      plan = plan!(io)
      lv = open!(conn, io)

      assert has_element?(
               lv,
               "#io-preview-group-#{s.uuid}-target",
               "There is already a draft #SO-#{draft.number} for this supplier"
             )

      refute has_element?(lv, "#io-preview-group-#{s.uuid}-new")
      assert has_element?(lv, "#io-preview-group-#{other.uuid}-new")

      assert has_element?(
               lv,
               "#io-preview-now-after-#{line_of(plan, a).index}",
               "in #SO-#{draft.number}: now 4 → 10"
             )

      assert has_element?(
               lv,
               "#io-preview-now-after-#{line_of(plan, b).index}",
               "now 0 → 3"
             )

      refute has_element?(lv, "#io-preview-now-after-#{line_of(plan, c).index}")

      assert has_element?(
               lv,
               "#io-preview-summary",
               "New orders: 1, appended: 1 (lines: 3); not ordered: 0"
             )
    end

    test "the warning is translated in every bundled language" do
      msgid =
        "There is already a draft %{number} for this supplier — what is missing will be added to it"

      for {locale, expected} <- [
            {"ru",
             "Для этого поставщика уже есть черновик #SO-12 — недостающее будет дописано в него"},
            {"et", "Sellel tarnijal on juba mustand #SO-12 — puuduv lisatakse sellesse"},
            {"uk", "Для цього постачальника вже є чернетка #SO-12 — відсутнє буде дописано в неї"}
          ] do
        Gettext.with_locale(PhoenixKitWarehouse.Gettext, locale, fn ->
          assert Gettext.dgettext(PhoenixKitWarehouse.Gettext, "default", msgid, number: "#SO-12") ==
                   expected
        end)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Choices
  # ---------------------------------------------------------------------------

  describe "choices" do
    test "a manual choice moves the line to its supplier and changes the summary",
         %{conn: conn} do
      [s_a, s_b] = [supplier!(), supplier!()]
      ambiguous = item_of!([s_a, s_b])
      io = posted_io!([io_line(ambiguous, "4")])
      plan = plan!(io)
      key = line_of(plan, ambiguous).key
      lv = open!(conn, io)

      assert has_element?(lv, "#io-preview-submit[disabled]")

      change!(lv, %{"choice" => %{key => s_b.uuid}})

      assert has_element?(lv, "#io-preview-group-#{s_b.uuid} #{row(plan, ambiguous)}")
      assert has_element?(lv, row(plan, ambiguous), "Chosen by hand")
      refute has_element?(lv, "#io-preview-choose")
      refute has_element?(lv, "#io-preview-submit[disabled]")

      assert has_element?(
               lv,
               "#io-preview-summary",
               "New orders: 1, appended: 0 (lines: 1); not ordered: 0"
             )
    end

    test "an automatic supplier can be replaced, or the line not ordered", %{conn: conn} do
      [s, other] = [supplier!(), supplier!()]
      item = item_of!([s])
      io = posted_io!([io_line(item, "4")])
      plan = plan!(io)
      key = line_of(plan, item).key
      lv = open!(conn, io)

      change!(lv, %{"choice" => %{key => other.uuid}})

      assert has_element?(lv, "#io-preview-group-#{other.uuid} #{row(plan, item)}")
      refute has_element?(lv, "#io-preview-group-#{s.uuid}")
      assert has_element?(lv, row(plan, item), "Chosen by hand")

      change!(lv, %{"choice" => %{key => "skip"}})

      assert has_element?(lv, "#io-preview-choose #{row(plan, item)}")
      assert has_element?(lv, row(plan, item), "Not ordered: chosen by hand")

      assert has_element?(
               lv,
               "#io-preview-summary",
               "New orders: 0, appended: 0 (lines: 0); not ordered: 1"
             )

      # Back to its own supplier: no choice any more, the automatic reason.
      change!(lv, %{"choice" => %{key => s.uuid}})

      assert has_element?(lv, "#io-preview-group-#{s.uuid} #{row(plan, item)}")
      assert has_element?(lv, row(plan, item), "The only supplier of the manufacturer")
    end

    test "ticked lines get the supplier of the bulk select at once", %{conn: conn} do
      s = supplier!()
      [x, y, z] = for _ <- 1..3, do: item!()
      io = posted_io!([io_line(x, "1"), io_line(y, "2"), io_line(z, "3")])
      plan = plan!(io)
      [kx, ky, _kz] = Enum.map([x, y, z], &line_of(plan, &1).key)
      lv = open!(conn, io)

      assert has_element?(lv, "#io-preview-assign-selected[disabled]")

      change!(lv, %{"pick" => %{kx => "true", ky => "true"}, "bulk_supplier" => s.uuid})
      refute has_element?(lv, "#io-preview-assign-selected[disabled]")

      lv |> element("#io-preview-assign-selected") |> render_click()

      assert has_element?(lv, "#io-preview-group-#{s.uuid} #{row(plan, x)}")
      assert has_element?(lv, "#io-preview-group-#{s.uuid} #{row(plan, y)}")
      assert has_element?(lv, "#io-preview-choose #{row(plan, z)}")
      assert has_element?(lv, row(plan, x), "Chosen by hand")

      assert has_element?(
               lv,
               "#io-preview-summary",
               "New orders: 1, appended: 0 (lines: 2); not ordered: 1"
             )
    end

    test "a ticked line that left the block is not assigned by the bulk choice",
         %{conn: conn} do
      [s, bulk] = [supplier!(), supplier!()]
      [x, y] = for _ <- 1..2, do: item!()
      io = posted_io!([io_line(x, "1"), io_line(y, "2")])
      plan = plan!(io)
      kx = line_of(plan, x).key
      lv = open!(conn, io)

      change!(lv, %{"pick" => %{kx => "true"}})
      assert has_element?(lv, "#io-preview-choose", "Selected: 1")

      # The ticked line gets its own supplier: it leaves the block, the tick
      # with it, even though the browser still sends it.
      change!(lv, %{
        "choice" => %{kx => s.uuid},
        "pick" => %{kx => "true"},
        "bulk_supplier" => bulk.uuid
      })

      assert has_element?(lv, "#io-preview-choose", "Selected: 0")
      assert has_element?(lv, "#io-preview-assign-selected[disabled]")

      render_click(lv, "preview_assign_selected", %{})

      assert has_element?(lv, "#io-preview-group-#{s.uuid} #{row(plan, x)}")
      refute has_element?(lv, "#io-preview-group-#{bulk.uuid}")
      assert has_element?(lv, "#io-preview-choose #{row(plan, y)}")
    end

    test "Select all ticks every line of the block", %{conn: conn} do
      s = supplier!()
      items = for _ <- 1..3, do: item!()
      io = posted_io!(Enum.map(items, &io_line(&1, "1")))
      plan = plan!(io)
      lv = open!(conn, io)

      change!(lv, %{"_target" => ["pick_all"], "pick_all" => "true", "bulk_supplier" => s.uuid})

      for item <- items do
        assert has_element?(lv, "#io-preview-pick-#{line_of(plan, item).index}[checked]")
      end

      lv |> element("#io-preview-assign-selected") |> render_click()

      refute has_element?(lv, "#io-preview-choose")

      assert has_element?(
               lv,
               "#io-preview-summary",
               "New orders: 1, appended: 0 (lines: 3); not ordered: 0"
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Generate
  # ---------------------------------------------------------------------------

  describe "Generate" do
    test "writes exactly what the window shows", %{conn: conn} do
      [s, s_a, s_b, s_bulk] = for _ <- 1..4, do: supplier!()
      kept = item_of!([s])
      appended = item_of!([s])
      ambiguous = item_of!([s_a, s_b])
      none = item!()
      skipped = item!()
      covered = item_of!([s])
      stock!(covered, "9")

      io =
        posted_io!([
          io_line(kept, "5"),
          io_line(appended, "6"),
          io_line(ambiguous, "4"),
          io_line(none, "3"),
          io_line(skipped, "2"),
          io_line(covered, "1")
        ])

      draft = draft_of!(io, s, [so_line(kept, "5"), so_line(appended, "2")])
      plan = plan!(io)
      [ka, kn] = Enum.map([ambiguous, none], &line_of(plan, &1).key)
      choices = %{ka => s_b.uuid, kn => s_bulk.uuid}

      lv = open!(conn, io)
      change!(lv, %{"choice" => choices})

      assembled = SupplierOrders.assemble(plan, choices)

      # What the window shows is that assembly: its groups with their lines,
      # the lines left without a supplier and the summary.
      for order <- assembled.orders, key <- order.keys do
        index = Enum.find(plan.lines, &(&1.key == key)).index

        assert has_element?(
                 lv,
                 "#io-preview-group-#{order.supplier_uuid} #io-preview-line-#{index}"
               )
      end

      for line <- assembled.unplaced do
        assert has_element?(lv, "#io-preview-choose #io-preview-line-#{line.index}")
      end

      assert has_element?(
               lv,
               "#io-preview-summary",
               "New orders: 2, appended: 1 (lines: 3); not ordered: 1"
             )

      before = MapSet.new(all_orders(), & &1.uuid)

      result = submit!(lv)
      {:ok, _index, html} = follow_redirect(result, conn)

      assert html =~ "Supplier orders created: 2."
      assert html =~ "Appended to: #SO-#{draft.number}."
      assert html =~ "Lines not ordered: 1."

      created = Enum.reject(all_orders(), &MapSet.member?(before, &1.uuid))

      expected_new =
        for %{target: :new} = order <- assembled.orders, into: %{} do
          {order.supplier_uuid, json(order.lines)}
        end

      assert Map.new(created, &{&1.supplier_uuid, &1.lines}) == expected_new
      assert Map.keys(expected_new) |> Enum.sort() == Enum.sort([s_b.uuid, s_bulk.uuid])

      [target_order] = Enum.filter(assembled.orders, &(&1.target != :new))
      written = SupplierOrders.get_supplier_order!(draft.uuid)
      assert written.lines == json(SupplierOrders.target_lines(target_order, io.uuid))
      assert quantities(written.lines) == %{kept.uuid => "5", appended.uuid => "6"}

      assert length(orders_of(io)) == 3
    end

    test "the window and the flash count the lines not ordered alike", %{conn: conn} do
      s = supplier!()
      none = item!()
      io = posted_io!([io_line(item_of!([s]), "5"), io_line(none, "2"), gone_line("3")])
      plan = plan!(io)
      gone = Enum.find(plan.lines, &(&1.reason == :no_item))
      lv = open!(conn, io)

      # An item no longer in the catalogue is shown among the lines with
      # nothing to order, yet counted as not ordered, as the write reports it.
      assert has_element?(lv, "#io-preview-not-ordered #io-preview-line-#{gone.index}")

      assert has_element?(
               lv,
               "#io-preview-summary",
               "New orders: 1, appended: 0 (lines: 1); not ordered: 2"
             )

      {:ok, _index, html} = lv |> submit!() |> follow_redirect(conn)

      assert html =~ "Supplier orders created: 1."
      assert html =~ "Lines not ordered: 2."
    end

    test "a Generate sent with nothing to order writes nothing and stays", %{conn: conn} do
      [s_a, s_b] = [supplier!(), supplier!()]
      io = posted_io!([io_line(item_of!([s_a, s_b]), "4")])
      lv = open!(conn, io)
      before = snapshot()

      assert has_element?(lv, "#io-preview-submit[disabled]")

      html = submit!(lv)

      assert html =~ "Nothing to generate"
      assert has_element?(lv, "#io-generation-preview")
      assert snapshot() == before
    end

    test "a plan that went stale is shown again with the choices that still hold",
         %{conn: conn} do
      [s_a, s_b, s_gone] = for _ <- 1..3, do: supplier!()
      ambiguous = item_of!([s_a, s_b])
      none = item!()
      moved = item_of!([s_a])
      io = posted_io!([io_line(ambiguous, "4"), io_line(none, "3"), io_line(moved, "5")])
      plan = plan!(io)
      [ka, kn] = Enum.map([ambiguous, none], &line_of(plan, &1).key)

      lv = open!(conn, io)
      change!(lv, %{"choice" => %{ka => s_b.uuid, kn => s_gone.uuid}})
      before = snapshot()

      # Meanwhile: the chosen supplier of one line is deactivated and the stock
      # of another item changes.
      {:ok, _} = Catalogue.update_supplier(s_gone, %{status: "inactive"})
      stock!(moved, "2")

      submit!(lv)

      assert snapshot() == before
      assert has_element?(lv, "#io-generation-preview")
      assert has_element?(lv, "#io-preview-stale", "The data has changed")

      # Kept: the choice still allowed. Dropped and marked: the other one.
      assert has_element?(lv, "#io-preview-group-#{s_b.uuid} #{row(plan, ambiguous)}")
      assert has_element?(lv, "#io-preview-choose #{row(plan, none)}")
      assert has_element?(lv, "#io-preview-changed-#{line_of(plan, none).index}")
      assert has_element?(lv, "#io-preview-changed-#{line_of(plan, moved).index}")
      refute has_element?(lv, "#io-preview-changed-#{line_of(plan, ambiguous).index}")

      refute has_element?(
               lv,
               "#io-preview-choice-#{line_of(plan, none).index} option[value='#{s_gone.uuid}']"
             )

      # The second press writes the new plan.
      result = submit!(lv)
      {:ok, _index, _html} = follow_redirect(result, conn)

      orders = orders_of(io)
      assert Enum.sort(Enum.map(orders, & &1.supplier_uuid)) == Enum.sort([s_a.uuid, s_b.uuid])
      moved_order = Enum.find(orders, &(&1.supplier_uuid == s_a.uuid))
      assert quantities(moved_order.lines) == %{moved.uuid => "3"}
    end

    test "a second press of the same plan writes nothing more", %{conn: conn} do
      s = supplier!()
      item = item_of!([s])
      io = posted_io!([io_line(item, "5")])

      first = open!(conn, io)
      second = open!(conn, io)

      assert has_element?(first, "#io-preview-submit[phx-disable-with]")

      {:ok, _index, _html} = first |> submit!() |> follow_redirect(conn)
      written = snapshot()

      second |> submit!()

      assert snapshot() == written
      assert has_element?(second, "#io-preview-stale")
      assert [%{lines: [line]}] = orders_of(io)
      assert StockLedger.format_quantity(line["ordered_quantity"]) == "5"
      assert has_element?(second, "#io-preview-submit[disabled]")
    end

    test "an internal order sent to the trash meanwhile: refused, the window closes",
         %{conn: conn} do
      s = supplier!()
      io = posted_io!([io_line(item_of!([s]), "5")])
      lv = open!(conn, io)
      before = snapshot()

      Repo.update_all(from(o in InternalOrder, where: o.uuid == ^io.uuid),
        set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      html = submit!(lv)

      assert html =~ "moved to the trash"
      refute has_element?(lv, "#io-generation-preview")
      assert has_element?(lv, "#io-trash-banner")
      assert snapshot() == before
    end

    test "another error: a flash, the window stays open with its choices", %{conn: conn} do
      [s_a, s_b] = [supplier!(), supplier!()]
      ambiguous = item_of!([s_a, s_b])
      io = posted_io!([io_line(ambiguous, "4")])
      plan = plan!(io)
      lv = open!(conn, io)
      change!(lv, %{"choice" => %{line_of(plan, ambiguous).key => s_b.uuid}})
      before = snapshot()

      # The row itself is gone meanwhile: `:not_found`, neither trashed nor
      # unposted.
      Repo.delete_all(from(o in InternalOrder, where: o.uuid == ^io.uuid))

      html = submit!(lv)

      assert html =~ "Failed to generate supplier orders"
      assert has_element?(lv, "#io-generation-preview")
      assert has_element?(lv, "#io-preview-group-#{s_b.uuid} #{row(plan, ambiguous)}")
      assert snapshot() == before
    end

    test "a choice the write refuses: a flash, the window stays open", %{conn: conn} do
      s = supplier!()
      [s_a, s_b] = [supplier!(), supplier!()]
      auto = item_of!([s])
      ambiguous = item_of!([s_a, s_b])
      io = posted_io!([io_line(auto, "5"), io_line(ambiguous, "4")])
      plan = plan!(io)
      key = line_of(plan, ambiguous).key
      lv = open!(conn, io)
      before = snapshot()

      # A choice the window would not offer (sent by hand, say).
      :sys.replace_state(lv.pid, fn state ->
        put_in(state.socket.assigns.preview.choices, %{key => Ecto.UUID.generate()})
      end)

      html = submit!(lv)

      assert html =~ "A chosen supplier cannot be used for a line"
      assert has_element?(lv, "#io-generation-preview")
      assert has_element?(lv, "#io-preview-choose #{row(plan, ambiguous)}")
      assert snapshot() == before
    end

    test "the window's events of an internal order in the trash are refused", %{conn: conn} do
      s = supplier!()
      io = posted_io!([io_line(item_of!([s]), "5")])
      events = ~w(preview_change preview_assign_selected preview_confirm)
      views = Map.new(events, &{&1, open!(conn, io)})
      before = snapshot()

      Repo.update_all(from(o in InternalOrder, where: o.uuid == ^io.uuid),
        set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      trashed = InternalOrders.get_internal_order!(io.uuid)

      # Each event arrives at a form that already shows the document as
      # trashed while its window is still open (a stale event): refused, the
      # window closes, nothing is written.
      for {event, lv} <- views do
        :sys.replace_state(lv.pid, fn state ->
          put_in(state.socket.assigns.order, trashed)
        end)

        assert render_click(lv, event, %{}) =~ "moved to the trash"
        refute has_element?(lv, "#io-generation-preview")
        assert has_element?(lv, "#io-trash-banner")
      end

      assert snapshot() == before
    end
  end
end
