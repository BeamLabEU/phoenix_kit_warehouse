defmodule PhoenixKitWarehouse.Web.SupplierOrderFormStaleLiveTest do
  @moduledoc """
  The supplier order form and a draft that changed after the form read it:
  generation appended to the draft while it was open. Every write of the form
  answers "changed elsewhere", writes nothing and draws the stored draft;
  what generation appended stays. A tab switch does not make the form's old
  lines current, and writes of the form one after another are not stale.
  The context side (`expected_version`) is in `SupplierOrdersDraftVersionTest`.
  """
  use PhoenixKitWarehouse.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.SupplierOrders
  alias PhoenixKitWarehouse.Test.Repo

  @location "00000000-0000-0000-0000-000000000001"
  @stale "The draft was changed elsewhere — the current version is shown, repeat the action"

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp unique, do: System.unique_integer([:positive])

  defp admin! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "so-stale-#{unique()}@example.com",
        "password" => "password123456789",
        "first_name" => "Stale",
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

  defp supplier! do
    {:ok, supplier} = Catalogue.create_supplier(%{name: "Supplier #{unique()}", status: "active"})
    supplier
  end

  # An item whose only supplier is `supplier` (through its manufacturer).
  defp item_of!(supplier) do
    {:ok, mfr} = Catalogue.create_manufacturer(%{name: "Mfr #{unique()}", status: "active"})
    Catalogue.link_manufacturer_supplier(mfr.uuid, supplier.uuid)
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Cat #{unique()}", status: "active"})

    {:ok, item} =
      Catalogue.create_item(%{
        name: "Item #{unique()}",
        catalogue_uuid: catalogue.uuid,
        status: "active",
        manufacturer_uuid: mfr.uuid
      })

    item
  end

  defp io_line(item, qty) do
    %{
      "item_uuid" => item.uuid,
      "name" => item.name,
      "sku" => "",
      "unit" => "piece",
      "catalogue_uuid" => item.catalogue_uuid,
      "required_quantity" => qty
    }
  end

  defp posted_io!(lines) do
    {:ok, io} = InternalOrders.create_internal_order(%{location_uuid: @location, lines: lines})
    {:ok, posted} = InternalOrders.post_internal_order(io, nil)
    posted
  end

  defp so_line(item, qty) do
    %{
      "item_uuid" => item.uuid,
      "name" => item.name,
      "unit" => "piece",
      "required_quantity" => Decimal.new(qty),
      "shortfall_quantity" => Decimal.new(qty),
      "ordered_quantity" => Decimal.new(qty)
    }
  end

  defp reload(%{uuid: uuid}), do: SupplierOrders.get_supplier_order!(uuid)

  defp ordered(order, item) do
    case Enum.find(order.lines, &(&1["item_uuid"] == item.uuid)) do
      nil -> nil
      line -> line["ordered_quantity"] |> StockLedger.to_decimal() |> Decimal.to_string(:normal)
    end
  end

  defp form_path(order, tab \\ nil)
  defp form_path(order, nil), do: Routes.path("/admin/warehouse/supplier-orders/#{order.uuid}")
  defp form_path(order, tab), do: form_path(order) <> "/#{tab}"

  # A draft of the pair (internal order, supplier) with item `a` 3, opened in
  # a form; the form does not know yet that generation will append to it.
  setup %{conn: conn} do
    admin = admin!()
    supplier = supplier!()
    a = item_of!(supplier)
    b = item_of!(supplier)
    io = posted_io!([io_line(a, "5"), io_line(b, "4")])

    {:ok, draft} =
      SupplierOrders.create_supplier_order(%{
        supplier_uuid: supplier.uuid,
        location_uuid: @location,
        internal_order_uuid: io.uuid,
        lines: [so_line(a, "3")],
        source_refs: [%{"type" => "internal_order", "uuid" => io.uuid}]
      })

    {:ok,
     conn: log_in(conn, admin), admin: admin, supplier: supplier, a: a, b: b, io: io, draft: draft}
  end

  # Generation appends to the open draft: `a` 3 -> 5, `b` 4 new.
  defp generate!(%{io: io, draft: draft, a: a, b: b}) do
    {:ok, %{appended: [%{uuid: uuid}]}} = SupplierOrders.generate_from_internal_order(io, nil)
    assert uuid == draft.uuid

    appended = reload(draft)
    assert ordered(appended, a) == "5"
    assert ordered(appended, b) == "4"
    appended
  end

  # The Files tab may set the storage folder meanwhile; what the form writes
  # is what must not have changed.
  @written [:lines, :source_refs, :supplier_uuid, :note, :status, :deleted_at]

  defp assert_appended_kept(appended),
    do: assert(Map.take(reload(appended), @written) == Map.take(appended, @written))

  # The form draws the stored draft now: its two lines, not the buffer's one.
  defp assert_buffer_reread(lv, draft) do
    unless has_element?(lv, "#so-qty-0") do
      render_patch(lv, form_path(draft, "lines"))
    end

    assert has_element?(lv, "#so-qty-1")
  end

  # Writes `note` to the draft right after the first update of a supplier
  # order the form process makes (the save of "Post"), before the post: Ecto
  # emits the query event in the process that ran the query, so the handler
  # runs in the form's process, between its save and its post.
  defp write_after_first_save(form_pid, draft, note) do
    handler = "write-after-save-#{unique()}"
    done = {handler, :done}

    :telemetry.attach(
      handler,
      [:phoenix_kit_warehouse, :test, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if self() == form_pid and not Process.get(done, false) and
             String.starts_with?(query, ~s(UPDATE "phoenix_kit_warehouse_supplier_orders")) do
          Process.put(done, true)

          SQL.query!(
            Repo,
            "UPDATE phoenix_kit_warehouse_supplier_orders SET note = $1 WHERE uuid = $2",
            [note, Ecto.UUID.dump!(draft.uuid)]
          )
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # ---------------------------------------------------------------------------
  # A tab that read the draft before generation appended to it
  # ---------------------------------------------------------------------------

  describe "a form opened before generation appended to its draft" do
    test "Save draft: changed elsewhere, nothing written, the stored draft drawn", ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))
      refute has_element?(lv, "#so-qty-1")
      appended = generate!(ctx)

      html = lv |> element("button[phx-click=save_draft]") |> render_click()

      assert html =~ @stale
      refute html =~ "Draft saved"
      assert_appended_kept(appended)
      assert_buffer_reread(lv, ctx.draft)
    end

    test "Save draft after a quantity was typed keeps what generation appended", ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))
      appended = generate!(ctx)

      lv
      |> form("#so-qty-form-0", %{"index" => "0", "ordered_quantity" => "9"})
      |> render_change()

      html = lv |> element("button[phx-click=save_draft]") |> render_click()

      assert html =~ @stale
      assert_appended_kept(appended)
      assert has_element?(lv, "#so-qty-0[value='5']")
    end

    test "Post: changed elsewhere, not posted", ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))
      appended = generate!(ctx)

      html = lv |> element("button[phx-click=post]") |> render_click()

      assert html =~ @stale
      assert_appended_kept(appended)
      assert reload(appended).status == "draft"
      assert_buffer_reread(lv, ctx.draft)
    end

    test "Add 10% reserve: changed elsewhere, nothing written", ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))
      appended = generate!(ctx)

      html = lv |> element("button[phx-click=add_reserve]") |> render_click()

      assert html =~ @stale
      refute html =~ "10% reserve applied"
      assert_appended_kept(appended)
      assert_buffer_reread(lv, ctx.draft)
    end

    test "choosing another supplier: changed elsewhere, the supplier stays", ctx do
      other = supplier!()
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft))
      appended = generate!(ctx)

      html =
        lv
        |> form("form[phx-change=set_supplier]", %{"supplier_uuid" => other.uuid})
        |> render_change()

      assert html =~ @stale
      assert_appended_kept(appended)
      assert_buffer_reread(lv, ctx.draft)
    end

    test "importing from an internal order: changed elsewhere, nothing imported", ctx do
      other_io = posted_io!([io_line(item_of!(ctx.supplier), "6")])
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))
      appended = generate!(ctx)

      lv |> element("button[phx-click='open_source_picker']") |> render_click()

      lv
      |> element("input[phx-click='source_picker_toggle'][phx-value-uuid='#{other_io.uuid}']")
      |> render_click()

      html = lv |> element("button[phx-click='source_picker_confirm']") |> render_click()

      assert html =~ @stale
      refute html =~ "Lines imported"
      assert_appended_kept(appended)
      refute has_element?(lv, "button[phx-click=source_picker_confirm]")
      assert_buffer_reread(lv, ctx.draft)
    end

    test "attaching an internal order: changed elsewhere, no link written", ctx do
      other_io = posted_io!([])
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft))
      appended = generate!(ctx)

      lv |> element("button[phx-click='open_link_picker']") |> render_click()

      lv
      |> element("input[phx-click='source_picker_toggle'][phx-value-uuid='#{other_io.uuid}']")
      |> render_click()

      html = lv |> element("button[phx-click='source_picker_confirm']") |> render_click()

      assert html =~ @stale
      refute html =~ "Link added"
      assert_appended_kept(appended)
      assert_buffer_reread(lv, ctx.draft)
    end

    test "removing a link: changed elsewhere, the link stays", ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft))
      appended = generate!(ctx)

      html =
        lv
        |> element("button[phx-click='remove_source_ref'][phx-value-uuid='#{ctx.io.uuid}']")
        |> render_click()

      assert html =~ @stale
      assert_appended_kept(appended)
      assert_buffer_reread(lv, ctx.draft)
    end

    test "Lines -> Files -> Lines does not make the old lines current", ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))
      appended = generate!(ctx)

      render_patch(lv, form_path(ctx.draft, "files"))
      render_patch(lv, form_path(ctx.draft, "lines"))
      # The tab switch reads the document, not the lines being edited.
      refute has_element?(lv, "#so-qty-1")

      html = lv |> element("button[phx-click=save_draft]") |> render_click()

      assert html =~ @stale
      assert_appended_kept(appended)
      assert_buffer_reread(lv, ctx.draft)
    end

    test "after the reread the action goes through", ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))
      generate!(ctx)

      assert lv |> element("button[phx-click=save_draft]") |> render_click() =~ @stale
      html = lv |> element("button[phx-click=save_draft]") |> render_click()

      assert html =~ "Draft saved"
      assert ordered(reload(ctx.draft), ctx.b) == "4"
    end

    test "a draft that went to the trash meanwhile still says so, not changed elsewhere",
         ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))
      generate!(ctx)
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(reload(ctx.draft), ctx.admin.uuid)

      html = lv |> element("button[phx-click=save_draft]") |> render_click()

      assert html =~ "Document moved to the trash"
      refute html =~ @stale
      assert has_element?(lv, "#so-trash-banner")
    end
  end

  # ---------------------------------------------------------------------------
  # One tab, writes one after another
  # ---------------------------------------------------------------------------

  describe "writes of one form one after another" do
    test "Save draft twice, Add 10% reserve, then Post: never changed elsewhere", ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))

      lv
      |> form("#so-qty-form-0", %{"index" => "0", "ordered_quantity" => "7"})
      |> render_change()

      assert lv |> element("button[phx-click=save_draft]") |> render_click() =~ "Draft saved"

      lv
      |> form("#so-qty-form-0", %{"index" => "0", "ordered_quantity" => "8,5"})
      |> render_change()

      html = lv |> element("button[phx-click=save_draft]") |> render_click()
      refute html =~ @stale
      assert ordered(reload(ctx.draft), ctx.a) == "8.5"

      html = lv |> element("button[phx-click=add_reserve]") |> render_click()
      assert html =~ "10% reserve applied"
      refute html =~ @stale

      assert {:error, {:live_redirect, _}} =
               lv |> element("button[phx-click=post]") |> render_click()

      assert reload(ctx.draft).status == "posted"
    end

    test "Post right after a typed quantity posts what was typed", ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))

      lv
      |> form("#so-qty-form-0", %{"index" => "0", "ordered_quantity" => "6"})
      |> render_change()

      assert {:error, {:live_redirect, _}} =
               lv |> element("button[phx-click=post]") |> render_click()

      posted = reload(ctx.draft)
      assert posted.status == "posted"
      assert ordered(posted, ctx.a) == "6"
    end

    test "Post: a write between its save and its post is not posted unseen", ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))

      lv
      |> form("#so-qty-form-0", %{"index" => "0", "ordered_quantity" => "6"})
      |> render_change()

      written_between = "written between the save and the post"
      write_after_first_save(lv.pid, ctx.draft, written_between)

      result = lv |> element("button[phx-click=post]") |> render_click()

      assert is_binary(result) and result =~ @stale
      stored = reload(ctx.draft)
      assert stored.status == "draft"
      assert stored.note == written_between
      assert ordered(stored, ctx.a) == "6"
    end

    test "supplier, a link and its removal, then Save draft: never changed elsewhere", ctx do
      other = supplier!()
      other_io = posted_io!([])
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft))

      html =
        lv
        |> form("form[phx-change=set_supplier]", %{"supplier_uuid" => other.uuid})
        |> render_change()

      refute html =~ @stale

      lv |> element("button[phx-click='open_link_picker']") |> render_click()

      lv
      |> element("input[phx-click='source_picker_toggle'][phx-value-uuid='#{other_io.uuid}']")
      |> render_click()

      assert lv |> element("button[phx-click='source_picker_confirm']") |> render_click() =~
               "Link added"

      html =
        lv
        |> element("button[phx-click='remove_source_ref'][phx-value-uuid='#{other_io.uuid}']")
        |> render_click()

      refute html =~ @stale

      assert lv |> element("button[phx-click=save_draft]") |> render_click() =~ "Draft saved"
      assert reload(ctx.draft).supplier_uuid == other.uuid
    end

    test "an import, then Save draft: never changed elsewhere", ctx do
      other_io = posted_io!([io_line(item_of!(ctx.supplier), "6")])
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))

      lv |> element("button[phx-click='open_source_picker']") |> render_click()

      lv
      |> element("input[phx-click='source_picker_toggle'][phx-value-uuid='#{other_io.uuid}']")
      |> render_click()

      assert lv |> element("button[phx-click='source_picker_confirm']") |> render_click() =~
               "Lines imported"

      assert lv |> element("button[phx-click=save_draft]") |> render_click() =~ "Draft saved"
    end
  end

  # ---------------------------------------------------------------------------
  # The version the form keeps after its own writes, and without one
  # ---------------------------------------------------------------------------

  describe "the version after the form's own writes" do
    test "attaching two internal orders at once writes both links", ctx do
      first = posted_io!([])
      second = posted_io!([])
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft))

      lv |> element("button[phx-click='open_link_picker']") |> render_click()

      for io <- [first, second] do
        lv
        |> element("input[phx-click='source_picker_toggle'][phx-value-uuid='#{io.uuid}']")
        |> render_click()
      end

      html = lv |> element("button[phx-click='source_picker_confirm']") |> render_click()

      assert html =~ "Link added"
      refute html =~ @stale
      refs = reload(ctx.draft).source_refs
      assert %{"type" => "internal_order", "uuid" => first.uuid} in refs
      assert %{"type" => "internal_order", "uuid" => second.uuid} in refs
    end

    test "after a correction of a posted order a link is attached, not changed elsewhere",
         ctx do
      {:ok, posted} = SupplierOrders.post_supplier_order(ctx.draft, ctx.admin.uuid)
      other_io = posted_io!([])
      {:ok, lv, _html} = live(ctx.conn, form_path(posted))

      lv |> form("form:has(#so-note-posted-input)", %{"note" => "corrected"}) |> render_change()

      assert lv |> element("button[phx-click=save_correction]") |> render_click() =~
               "Correction saved"

      assert reload(posted).note == "corrected"

      lv |> element("button[phx-click='open_link_picker']") |> render_click()

      lv
      |> element("input[phx-click='source_picker_toggle'][phx-value-uuid='#{other_io.uuid}']")
      |> render_click()

      html = lv |> element("button[phx-click='source_picker_confirm']") |> render_click()

      assert html =~ "Link added"
      refute html =~ @stale
      assert %{"type" => "internal_order", "uuid" => other_io.uuid} in reload(posted).source_refs
    end

    test "Post that saved but could not post: the next save is not changed elsewhere",
         ctx do
      {:ok, draft} =
        SupplierOrders.create_supplier_order(%{
          location_uuid: @location,
          lines: [so_line(ctx.a, "3")]
        })

      {:ok, lv, _html} = live(ctx.conn, form_path(draft, "lines"))

      lv
      |> form("#so-qty-form-0", %{"index" => "0", "ordered_quantity" => "6"})
      |> render_change()

      html = lv |> element("button[phx-click=post]") |> render_click()

      assert html =~ "Cannot post: please set a supplier first"
      assert ordered(reload(draft), ctx.a) == "6"

      lv
      |> form("#so-qty-form-0", %{"index" => "0", "ordered_quantity" => "7"})
      |> render_change()

      html = lv |> element("button[phx-click=save_draft]") |> render_click()

      assert html =~ "Draft saved"
      refute html =~ @stale
      assert ordered(reload(draft), ctx.a) == "7"
    end

    test "a form without a version does not write unchecked: it reads the draft again",
         ctx do
      {:ok, lv, _html} = live(ctx.conn, form_path(ctx.draft, "lines"))

      lv
      |> form("#so-qty-form-0", %{"index" => "0", "ordered_quantity" => "9"})
      |> render_change()

      :sys.replace_state(lv.pid, fn state ->
        %{state | socket: Phoenix.Component.assign(state.socket, :draft_version, nil)}
      end)

      html = lv |> element("button[phx-click=save_draft]") |> render_click()

      assert html =~ @stale
      refute html =~ "Draft saved"
      assert ordered(reload(ctx.draft), ctx.a) == "3"
      assert has_element?(lv, "#so-qty-0[value='3']")

      html = lv |> element("button[phx-click=save_draft]") |> render_click()
      assert html =~ "Draft saved"
    end
  end
end
