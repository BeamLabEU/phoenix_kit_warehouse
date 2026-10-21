defmodule PhoenixKitWarehouse.Web.DocumentTrashFormLiveTest do
  @moduledoc """
  The form of a goods receipt, goods issue, stocktake or transfer that is in
  the trash: the banner, the write actions it hides, the server-side refusal of
  their events (`@trash_blocked`), the Files tab that makes no folder, a write
  of a document that went to the trash meanwhile, a document restored in
  another tab, the legacy transfer in transit that sits in the trash, and the
  warning when a restored goods issue over-reserves an internal order.
  """
  use PhoenixKitWarehouse.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.{ItemSupplierInfos, Suppliers}

  alias PhoenixKitWarehouse.{
    GoodsIssue,
    GoodsIssues,
    GoodsReceipt,
    GoodsReceipts,
    InternalOrders,
    Inventories,
    InventoryDocument,
    StockLedger,
    SupplierOrders,
    Transfer,
    Transfers
  }

  alias PhoenixKitWarehouse.Test.{Fixtures, Repo}

  @location "00000000-0000-0000-0000-000000000001"
  @other_location "00000000-0000-0000-0000-0000000000b1"
  @source_location "00000000-0000-0000-0000-0000000000a1"
  @destination_location "00000000-0000-0000-0000-0000000000a2"

  @moved "Document moved to the trash"

  setup do
    Repo.delete_all(GoodsReceipt)
    Repo.delete_all(GoodsIssue)
    Repo.delete_all(InventoryDocument)
    Repo.delete_all(Transfer)

    {:ok, admin: admin!()}
  end

  defp admin! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "doc-trash-form-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "Trash",
        "last_name" => "Form"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.promote_to_admin(user)
    Auth.get_user!(user.uuid)
  end

  defp log_in(conn, user) do
    token = Auth.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  # ---------------------------------------------------------------------------
  # The four kinds
  # ---------------------------------------------------------------------------

  defp draft!(kind, attrs \\ %{})

  defp draft!(:gr, attrs) do
    {:ok, doc} =
      GoodsReceipts.create_goods_receipt(
        Map.merge(%{location_uuid: @location, lines: [line("received_quantity")]}, attrs)
      )

    doc
  end

  defp draft!(:gi, attrs) do
    item = Ecto.UUID.generate()
    seed!(item, @location)

    {:ok, doc} =
      GoodsIssues.create_goods_issue(
        Map.merge(%{location_uuid: @location, lines: [line(item, "issued_quantity")]}, attrs)
      )

    doc
  end

  defp draft!(:inv, attrs) do
    {:ok, doc} =
      Inventories.create_draft(
        Map.merge(%{location_uuid: @location, lines: [line("counted_quantity")]}, attrs)
      )

    doc
  end

  defp draft!(:tr, attrs) do
    item = Ecto.UUID.generate()
    seed!(item, @source_location)

    base = %{
      source_location_uuid: @source_location,
      destination_location_uuid: @destination_location,
      lines: [line(item, "transfer_quantity")]
    }

    {:ok, doc} = Transfers.create_transfer(Map.merge(base, attrs))
    doc
  end

  # A document past its draft: posted, or a transfer that is done.
  defp finished!(:gr), do: finished!(:gr, draft!(:gr))
  defp finished!(:gi), do: ok!(GoodsIssues.post_goods_issue(draft!(:gi), nil))
  defp finished!(:inv), do: ok!(Inventories.post_document(draft!(:inv), nil))
  defp finished!(:tr), do: ok!(Transfers.receive_transfer(in_transit!(), nil))

  defp finished!(:gr, draft), do: ok!(GoodsReceipts.post_goods_receipt(draft, nil))

  defp in_transit!, do: ok!(Transfers.ship_transfer(draft!(:tr), nil))

  defp trash!(:gr, doc, actor), do: ok!(GoodsReceipts.soft_delete(doc, actor.uuid))
  defp trash!(:gi, doc, actor), do: ok!(GoodsIssues.soft_delete(doc, actor.uuid))
  defp trash!(:inv, doc, actor), do: ok!(Inventories.soft_delete_document(doc, actor.uuid))
  defp trash!(:tr, doc, actor), do: ok!(Transfers.soft_delete_transfer(doc, actor.uuid))

  defp restore!(:gr, doc), do: ok!(GoodsReceipts.restore_goods_receipt(doc, nil))
  defp restore!(:gi, doc), do: ok!(GoodsIssues.restore_goods_issue(doc, nil))
  defp restore!(:inv, doc), do: ok!(Inventories.restore_document(doc, nil))
  defp restore!(:tr, doc), do: ok!(Transfers.restore_transfer(doc, nil))

  defp schema(:gr), do: GoodsReceipt
  defp schema(:gi), do: GoodsIssue
  defp schema(:inv), do: InventoryDocument
  defp schema(:tr), do: Transfer

  defp reload(kind, doc), do: Repo.get!(schema(kind), doc.uuid)

  # Old code could trash any status with a plain update; the legacy fixtures
  # do the same.
  defp force_trash!(kind, doc, actor) do
    {1, _} =
      Repo.update_all(from(d in schema(kind), where: d.uuid == ^doc.uuid),
        set: [
          deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          deleted_by_uuid: actor.uuid
        ]
      )

    reload(kind, doc)
  end

  defp base_path(:gr), do: "/admin/warehouse/goods-receipts"
  defp base_path(:gi), do: "/admin/warehouse/goods-issues"
  defp base_path(:inv), do: "/admin/warehouse/inventory"
  defp base_path(:tr), do: "/admin/warehouse/transfers"

  defp form_path(kind, doc, tab \\ ""), do: Routes.path("#{base_path(kind)}/#{doc.uuid}#{tab}")

  # The tab with the lines.
  defp lines_tab(kind) when kind in [:gr, :gi], do: "/lines"
  defp lines_tab(_kind), do: "/items"

  defp files_tab, do: "/files"

  # The events a trashed draft refuses, with params a live draft would send.
  # Without the guard each of them either writes, opens something or answers
  # differently, so every one of them needs the guard to say "moved to the trash".
  defp draft_events(:gr) do
    [
      {"set_received_qty", %{"index" => "0", "received_quantity" => "9"}},
      {"receive_all", %{}},
      {"set_location", %{"location_uuid" => @other_location}},
      {"save_draft", %{}},
      {"post", %{}},
      {"open_source_picker", %{}},
      {"open_link_picker", %{"kind" => "order"}},
      {"source_picker_confirm", %{}},
      {"remove_source_ref", %{"type" => "order", "uuid" => Ecto.UUID.generate()}}
    ]
  end

  defp draft_events(:gi) do
    [
      {"set_issued_qty", %{"index" => "0", "issued_quantity" => "9"}},
      {"set_location", %{"location_uuid" => @other_location}},
      {"set_reason", %{"reason" => "write_off"}},
      {"save_draft", %{}},
      {"post", %{}},
      {"open_io_picker", %{}},
      {"open_link_picker", %{"kind" => "order"}},
      {"source_picker_confirm", %{}},
      {"remove_source_ref", %{"type" => "order", "uuid" => Ecto.UUID.generate()}}
    ]
  end

  defp draft_events(:inv) do
    [
      {"open_item_selector", %{}},
      {"remove_line", %{"index" => "0"}},
      {"set_counted", %{"index" => "0", "counted_quantity" => "9"}},
      {"set_price", %{"index" => "0", "unit_value" => "9"}},
      {"set_sum", %{"index" => "0", "sum" => "9"}},
      {"toggle_track_value", %{}},
      {"set_location", %{"location_uuid" => @other_location}},
      {"confirm_location_change", %{}},
      {"set_responsibility", %{"performed_by_uuid" => Ecto.UUID.generate()}},
      {"save_draft", %{}},
      {"post", %{}}
    ]
  end

  defp draft_events(:tr) do
    [
      {"open_item_selector", %{}},
      {"open_link_picker", %{}},
      {"source_picker_confirm", %{}},
      {"remove_source_ref", %{"type" => "order", "uuid" => Ecto.UUID.generate()}},
      {"remove_line", %{"index" => "0"}},
      {"set_transfer_qty", %{"index" => "0", "transfer_quantity" => "9"}},
      {"set_source_location", %{"location_uuid" => @other_location}},
      {"set_destination_location", %{"location_uuid" => @other_location}},
      {"save_draft", %{}},
      {"ship", %{}},
      {"cancel", %{}},
      {"open_cancel_confirm", %{}},
      {"receive", %{}}
    ]
  end

  # The events a trashed finished document refuses.
  defp finished_events(:inv), do: ~w(save_correction repost set_responsibility)
  defp finished_events(_kind), do: ~w(save_correction)

  defp line(quantity_key), do: line(Ecto.UUID.generate(), quantity_key)

  defp line(item_uuid, quantity_key) do
    %{"item_uuid" => item_uuid, "name" => "Material", "unit" => "pcs", quantity_key => "4"}
  end

  defp seed!(item_uuid, location) do
    {:ok, _} = StockLedger.upsert_quantity(item_uuid, Decimal.new("10"), location_uuid: location)
  end

  defp ok!({:ok, value}), do: value

  defp uniq, do: System.unique_integer([:positive])

  defp clear_error_flash(lv), do: render_click(lv, "lv:clear-flash", %{"key" => "error"})

  # What a refused event must leave as it was.
  defp snapshot(doc) do
    Map.take(doc, [
      :status,
      :note,
      :lines,
      :deleted_at,
      :source_refs,
      :location_uuid,
      :source_location_uuid,
      :destination_location_uuid,
      :reason,
      :performed_by_uuid,
      :track_value
    ])
  end

  for kind <- [:gr, :gi, :inv, :tr] do
    @kind kind
    @p Atom.to_string(kind)

    describe "#{@p} form of a trashed draft" do
      test "shows the banner and Restore, hides the write actions", %{conn: conn} = ctx do
        trashed = trash!(@kind, draft!(@kind), ctx.admin)
        conn = log_in(conn, ctx.admin)

        {:ok, lv, _html} = live(conn, form_path(@kind, trashed))

        assert has_element?(lv, "##{@p}-trash-banner")
        assert has_element?(lv, "##{@p}-restore")
        refute has_element?(lv, "##{@p}-trash")
        refute has_element?(lv, "a[href$='/files']")

        for event <- ~w(save_draft post ship cancel open_cancel_confirm receive
                        open_link_picker remove_source_ref toggle_track_value) do
          refute has_element?(lv, "[phx-click=#{event}]"), "#{event} is shown"
        end

        for event <- ~w(set_note set_location set_reason set_responsibility
                        set_source_location set_destination_location) do
          refute has_element?(lv, "form[phx-change=#{event}]"), "#{event} is shown"
        end

        {:ok, lv, _html} = live(conn, form_path(@kind, trashed, lines_tab(@kind)))

        for event <- ~w(open_source_picker receive_all open_io_picker open_item_selector
                        remove_line) do
          refute has_element?(lv, "[phx-click=#{event}]"), "#{event} is shown"
        end

        refute has_element?(lv, "form[phx-change^=set_]")
      end

      test "the write events are refused and write nothing", %{conn: conn} = ctx do
        trashed = trash!(@kind, draft!(@kind), ctx.admin)
        before = snapshot(trashed)

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, trashed))

        for {event, params} <- draft_events(@kind) do
          clear_error_flash(lv)
          render_click(lv, event, params)
          assert has_element?(lv, "#flash-error", @moved), "#{event} was not refused"
        end

        assert has_element?(lv, "##{@p}-trash-banner")
        refute has_element?(lv, "[phx-click=source_picker_confirm]")
        assert snapshot(reload(@kind, trashed)) == before
      end

      test "the Files tab neither looks for nor makes a storage folder", %{conn: conn} = ctx do
        trashed = trash!(@kind, draft!(@kind), ctx.admin)

        {:ok, lv, html} = live(log_in(conn, ctx.admin), form_path(@kind, trashed, files_tab()))

        refute html =~ "Loading files"
        refute render(lv) =~ "Loading files"
        assert render(lv) =~ "Files are not available"
        assert reload(@kind, trashed).storage_folder_uuid == nil

        send(lv.pid, {:files_folder_result, {:ok, %{uuid: Ecto.UUID.generate()}}})
        refute has_element?(lv, "[id^=media-browser-]")
      end

      test "Restore on the Files tab starts looking for the storage folder",
           %{conn: conn} = ctx do
        trashed = trash!(@kind, draft!(@kind), ctx.admin)

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, trashed, files_tab()))

        html = lv |> element("##{@p}-restore") |> render_click()

        assert reload(@kind, trashed).deleted_at == nil
        assert html =~ "Loading files"
        refute html =~ "Files are not available"
      end

      test "a document restored in another tab goes back to the live form", %{conn: conn} = ctx do
        trashed = trash!(@kind, draft!(@kind), ctx.admin)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, trashed))
        restore!(@kind, trashed)

        render_click(lv, "save_draft", %{})

        refute has_element?(lv, "#flash-error", @moved)
        refute has_element?(lv, "##{@p}-trash-banner")
        assert has_element?(lv, "button[phx-click=save_draft]")
      end
    end

    describe "#{@p} form of a trashed finished document (legacy)" do
      test "shows the banner without Restore and refuses the correction", %{conn: conn} = ctx do
        legacy = force_trash!(@kind, finished!(@kind), ctx.admin)
        before = snapshot(legacy)

        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, legacy))

        assert has_element?(lv, "##{@p}-trash-banner")
        refute has_element?(lv, "##{@p}-restore")
        refute has_element?(lv, "##{@p}-trash")
        refute has_element?(lv, "[phx-click=save_correction]")
        refute has_element?(lv, "[phx-click=repost]")
        refute has_element?(lv, "form[phx-change=set_responsibility]")

        render_change(lv, "set_note", %{"note" => "changed"})

        for event <- finished_events(@kind) do
          clear_error_flash(lv)
          render_click(lv, event, %{"performed_by_uuid" => ctx.admin.uuid})
          assert has_element?(lv, "#flash-error", @moved), "#{event} was not refused"
        end

        assert snapshot(reload(@kind, legacy)) == before
      end
    end

    describe "#{@p} form: a write of a draft that went to the trash meanwhile" do
      test "Save draft says so, writes nothing and draws the form as trashed",
           %{conn: conn} = ctx do
        draft = draft!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))
        render_change(lv, "set_note", %{"note" => "unsaved"})
        trash!(@kind, draft, ctx.admin)

        render_click(lv, "save_draft", %{})

        assert has_element?(lv, "#flash-error", @moved)
        assert has_element?(lv, "##{@p}-trash-banner")
        assert reload(@kind, draft).note == nil
      end

      test "posting says so and moves nothing", %{conn: conn} = ctx do
        draft = draft!(@kind)
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))
        trash!(@kind, draft, ctx.admin)

        render_click(lv, if(@kind == :tr, do: "ship", else: "post"), %{})

        assert has_element?(lv, "#flash-error", @moved)
        assert has_element?(lv, "##{@p}-trash-banner")
        assert reload(@kind, draft).status == "draft"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Writes of one kind that went to the trash meanwhile
  # ---------------------------------------------------------------------------

  describe "a draft that went to the trash meanwhile" do
    test "a goods receipt's import from a supplier order says so", %{conn: conn} = ctx do
      draft = draft!(:gr, %{lines: []})
      so = posted_supplier_order!()
      {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(:gr, draft, "/lines"))

      render_click(lv, "open_source_picker", %{})
      render_click(lv, "source_picker_toggle", %{"uuid" => so.uuid})
      trash!(:gr, draft, ctx.admin)
      render_click(lv, "source_picker_confirm", %{})

      assert has_element?(lv, "#flash-error", @moved)
      assert has_element?(lv, "#gr-trash-banner")
      assert reload(:gr, draft).lines == []
    end

    test "a goods issue's import from an internal order says so", %{conn: conn} = ctx do
      draft = draft!(:gi, %{lines: []})
      io = posted_internal_order!(Ecto.UUID.generate(), "5")
      {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(:gi, draft, "/lines"))

      render_click(lv, "open_io_picker", %{})
      render_click(lv, "source_picker_toggle", %{"uuid" => io.uuid})
      trash!(:gi, draft, ctx.admin)
      render_click(lv, "source_picker_confirm", %{})

      assert has_element?(lv, "#flash-error", @moved)
      assert has_element?(lv, "#gi-trash-banner")
      assert reload(:gi, draft).lines == []
    end

    test "a stocktake's change of warehouse says so", %{conn: conn} = ctx do
      draft = draft!(:inv)
      {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(:inv, draft))

      render_change(lv, "set_location", %{"location_uuid" => @other_location})
      trash!(:inv, draft, ctx.admin)
      render_click(lv, "confirm_location_change", %{})

      assert has_element?(lv, "#flash-error", @moved)
      assert has_element?(lv, "#inv-trash-banner")
      assert reload(:inv, draft).location_uuid == @location
    end

    test "a transfer draft's Cancel says so and does not cancel it", %{conn: conn} = ctx do
      draft = draft!(:tr)
      {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(:tr, draft))
      trash!(:tr, draft, ctx.admin)

      render_click(lv, "cancel", %{})

      assert has_element?(lv, "#flash-error", @moved)
      assert has_element?(lv, "#tr-trash-banner")
      assert reload(:tr, draft).status == "draft"
    end

    for kind <- [:gr, :gi, :tr] do
      @kind kind
      @p Atom.to_string(kind)

      test "#{@p}: adding a link says so and adds nothing", %{conn: conn} = ctx do
        draft = draft!(@kind)
        source = Fixtures.insert_order!()
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))

        render_click(lv, "open_link_picker", %{"kind" => "order"})
        render_click(lv, "source_picker_toggle", %{"uuid" => source.uuid})
        trash!(@kind, draft, ctx.admin)
        render_click(lv, "source_picker_confirm", %{})

        assert has_element?(lv, "#flash-error", @moved)
        assert has_element?(lv, "##{@p}-trash-banner")
        assert reload(@kind, draft).source_refs == []
      end

      test "#{@p}: removing a link says so and keeps it", %{conn: conn} = ctx do
        source = Fixtures.insert_order!()
        draft = draft!(@kind, %{source_refs: [%{"type" => "order", "uuid" => source.uuid}]})
        {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(@kind, draft))
        trash!(@kind, draft, ctx.admin)

        render_click(lv, "remove_source_ref", %{"type" => "order", "uuid" => source.uuid})

        assert has_element?(lv, "#flash-error", @moved)
        assert has_element?(lv, "##{@p}-trash-banner")
        assert [%{"uuid" => uuid}] = reload(@kind, draft).source_refs
        assert uuid == source.uuid
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Goods receipt: the catalogue prices a trashed posted receipt proposes
  # ---------------------------------------------------------------------------

  describe "a trashed posted goods receipt and the catalogue prices" do
    test "Update price and Update all prices are refused and the cost stays",
         %{conn: conn} = ctx do
      {:ok, supplier} =
        Catalogue.create_supplier(%{name: "Trash Price #{uniq()}", status: "active"})

      {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Cat #{uniq()}", status: "active"})

      {:ok, item} =
        Catalogue.create_item(%{
          name: "Item #{uniq()}",
          catalogue_uuid: catalogue.uuid,
          status: "active"
        })

      {:ok, _info} =
        ItemSupplierInfos.create(%{
          item_uuid: item.uuid,
          supplier_uuid: supplier.uuid,
          supplier_source: "local",
          unit_cost: Decimal.new("5"),
          currency: "EUR"
        })

      line = %{line(item.uuid, "received_quantity") | "name" => item.name}

      receipt =
        draft!(:gr, %{supplier_uuid: supplier.uuid, lines: [Map.put(line, "unit_value", "7")]})

      legacy = force_trash!(:gr, finished!(:gr, receipt), ctx.admin)

      {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(:gr, legacy, "/lines"))

      # The receipt does propose a new price; the trash is what keeps it out.
      assert [%{item_uuid: proposed}] = :sys.get_state(lv.pid).socket.assigns.price_proposals
      assert proposed == item.uuid
      refute has_element?(lv, "[phx-click=update_price]")

      for {event, params} <- [
            {"update_price", %{"item_uuid" => item.uuid}},
            {"update_all_prices", %{}}
          ] do
        clear_error_flash(lv)
        render_click(lv, event, params)
        assert has_element?(lv, "#flash-error", @moved), "#{event} was not refused"
        refute has_element?(lv, "#flash-info")
      end

      assert Decimal.equal?(
               Suppliers.active_info_for(item.uuid, supplier.uuid).unit_cost,
               Decimal.new("5")
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Transfer: Cancel and Receive depend on the status, not on the trash alone
  # ---------------------------------------------------------------------------

  describe "a legacy transfer in transit that sits in the trash" do
    test "shows the banner without Restore, and Receive and Cancel", %{conn: conn} = ctx do
      legacy = force_trash!(:tr, in_transit!(), ctx.admin)

      {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(:tr, legacy))

      assert has_element?(lv, "#tr-trash-banner")
      refute has_element?(lv, "#tr-restore")
      assert has_element?(lv, "button[phx-click=receive]")
      assert has_element?(lv, "button[phx-click=open_cancel_confirm]")
      refute has_element?(lv, "button[phx-click=ship]")
      refute has_element?(lv, "button[phx-click=save_draft]")
    end

    test "Receive still receives it", %{conn: conn} = ctx do
      legacy = force_trash!(:tr, in_transit!(), ctx.admin)
      {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(:tr, legacy))

      lv |> element("button[phx-click=receive]") |> render_click()

      assert reload(:tr, legacy).status == "done"
    end

    test "Cancel still cancels it", %{conn: conn} = ctx do
      legacy = force_trash!(:tr, in_transit!(), ctx.admin)
      {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(:tr, legacy))

      lv |> element("button[phx-click=open_cancel_confirm]") |> render_click()
      lv |> element("button[phx-click=cancel]") |> render_click()

      assert reload(:tr, legacy).status == "cancelled"
    end
  end

  # ---------------------------------------------------------------------------
  # Goods issue: a restore that over-reserves an internal order
  # ---------------------------------------------------------------------------

  describe "restoring a goods issue whose internal order was issued again meanwhile" do
    setup do
      io = posted_internal_order!(Ecto.UUID.generate(), "10")
      a = ok!(GoodsIssues.import_from_internal_orders(draft!(:gi, %{lines: []}), [io.uuid], nil))
      {:ok, io: io, a: a}
    end

    test "the list's Restore warns about the internal order", %{conn: conn} = ctx do
      a = trash!(:gi, ctx.a, ctx.admin)
      ok!(GoodsIssues.import_from_internal_orders(draft!(:gi, %{lines: []}), [ctx.io.uuid], nil))

      {:ok, lv, _html} =
        live(log_in(conn, ctx.admin), Routes.path("/admin/warehouse/goods-issues?view=trash"))

      lv |> element("#gi-restore-#{a.uuid}") |> render_click()

      assert has_element?(lv, "#flash-info", "Restored from the trash: #GI-#{a.number}.")

      assert has_element?(
               lv,
               "#flash-info",
               "Goods issues exceed the order for: #IO-#{ctx.io.number} — check the lines."
             )

      assert reload(:gi, a).deleted_at == nil
    end

    test "the form's Restore warns about the internal order", %{conn: conn} = ctx do
      a = trash!(:gi, ctx.a, ctx.admin)
      ok!(GoodsIssues.import_from_internal_orders(draft!(:gi, %{lines: []}), [ctx.io.uuid], nil))

      {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(:gi, a))
      lv |> element("#gi-restore") |> render_click()

      assert has_element?(lv, "#flash-info", "#IO-#{ctx.io.number}")
      assert has_element?(lv, "#flash-info", "check the lines")
      refute has_element?(lv, "#gi-trash-banner")
    end

    test "no warning while the internal order is not exceeded", %{conn: conn} = ctx do
      a = trash!(:gi, ctx.a, ctx.admin)

      {:ok, lv, _html} = live(log_in(conn, ctx.admin), form_path(:gi, a))
      lv |> element("#gi-restore") |> render_click()

      assert has_element?(lv, "#flash-info", "Restored from the trash: #GI-#{a.number}.")
      refute has_element?(lv, "#flash-info", "check the lines")
    end
  end

  defp posted_internal_order!(item_uuid, quantity) do
    {:ok, io} =
      InternalOrders.create_internal_order(%{
        location_uuid: @location,
        lines: [
          %{
            "item_uuid" => item_uuid,
            "name" => "Material",
            "unit" => "pcs",
            "required_quantity" => quantity
          }
        ]
      })

    ok!(InternalOrders.post_internal_order(io, nil))
  end

  defp posted_supplier_order! do
    {:ok, so} =
      SupplierOrders.create_supplier_order(%{
        location_uuid: @location,
        supplier_uuid: Ecto.UUID.generate(),
        lines: [line("ordered_quantity")]
      })

    ok!(SupplierOrders.post_supplier_order(so, nil))
  end
end
