defmodule PhoenixKitWarehouse.Web.InventoryAIPanelLiveTest do
  # The photo inventory on the Items tab (spec §5, §11): who sees it, the
  # proposal, Apply with the rules of the lines, discard, retry, the late
  # answer, the warehouse change, the posting, the server's checks.
  use PhoenixKitWarehouse.LiveCase, async: false

  import PhoenixKitWarehouse.Test.InventoryAIFixtures

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitLocations.Locations
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryAI
  alias PhoenixKitWarehouse.InventoryAI.Lines
  alias PhoenixKitWarehouse.InventoryAI.Settings
  alias PhoenixKitWarehouse.InventoryAIRun
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.StorageFolders
  alias PhoenixKitWarehouse.Test.InventoryAIStub
  alias PhoenixKitWarehouse.Web.InventoryAIPanel

  @registry_key {PhoenixKit, :registered_modules}
  @fixture Path.expand("../../fixtures/inventory_ai/shelf.jpg", __DIR__)

  setup %{conn: conn} do
    # The permission keys `warehouse` and `ai` exist only for registered modules.
    previous = :persistent_term.get(@registry_key, :none)
    :persistent_term.put(@registry_key, [PhoenixKitWarehouse, PhoenixKitAI])

    on_exit(fn ->
      if previous == :none,
        do: :persistent_term.erase(@registry_key),
        else: :persistent_term.put(@registry_key, previous)
    end)

    PhoenixKitWarehouse.enable_system()
    admin = owner!()
    ai_ready!()
    location = Ecto.UUID.generate()
    catalogue = catalogue!("Fittings")
    hinge = item!(catalogue, %{name: "Hinge", sku: "H-1"})
    screw = item!(catalogue, %{name: "Screw", sku: "S-1"})
    stock!(hinge, location, "500")
    doc = draft!(location)

    %{
      conn: log_in(conn, admin),
      admin: admin,
      location: location,
      catalogue: catalogue,
      hinge: hinge,
      screw: screw,
      doc: doc
    }
  end

  defp items_path(doc), do: Routes.path("/admin/warehouse/inventory/#{doc.uuid}/items")
  defp repo, do: PhoenixKit.RepoHelper.repo()

  # The catalogue numbers of the setup: 1 Hinge, 2 Screw.
  defp run!(ctx, place, objects, doc \\ nil),
    do: proposed_run!(doc || ctx.doc, place, objects, [ctx.catalogue.uuid])

  defp open!(ctx, doc \\ nil) do
    {:ok, lv, _html} = live(ctx.conn, items_path(doc || ctx.doc))
    lv
  end

  defp open_run(lv, run) do
    lv |> element("#inventory-ai-open-run-#{run.uuid}") |> render_click()
    assert has_element?(lv, "#inventory-ai-proposal-#{run.uuid}")
    lv
  end

  defp apply(lv), do: lv |> element("#inventory-ai-apply") |> render_click()

  defp photo_input(lv, name \\ "shelf.jpg", content \\ "not really a photo") do
    file_input(lv, "#inventory-ai-upload-form", :inventory_ai_photos, [
      %{name: name, content: content, type: "image/jpeg"}
    ])
  end

  # A real photo, for a run that reads it.
  defp jpeg_input(lv) do
    file_input(lv, "#inventory-ai-upload-form", :inventory_ai_photos, [
      %{name: "shelf.jpg", content: File.read!(@fixture), type: "image/jpeg"}
    ])
  end

  # A confirmed user whose one role holds only the permission `key`.
  defp role_user!(key) do
    {:ok, role} = Roles.create_role(%{name: "Only#{key}#{System.unique_integer([:positive])}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, key)
    {:ok, user} = Auth.admin_confirm_user(user!())
    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  defp line(doc, item),
    do: Enum.find(Inventories.get_document!(doc.uuid).lines, &(&1["item_uuid"] == item.uuid))

  defp counted(doc, item), do: Lines.decimal(line(doc, item)["counted_quantity"])

  defp status(run), do: repo().get!(InventoryAIRun, run.uuid).status

  defp checked?(lv, key),
    do: has_element?(lv, "#inventory-ai-check-#{key}[checked]")

  defp tick(lv, key), do: lv |> element("#inventory-ai-check-#{key}") |> render_click()

  defp set_inputs(lv, key, values) do
    lv |> form("#inventory-ai-inputs-#{key}", values) |> render_change()
  end

  # Applies the proposal's rows `keys` (ticking those not ticked by default).
  defp apply_rows!(ctx, run, keys, doc \\ nil) do
    lv = open!(ctx, doc) |> open_run(run)
    for key <- keys, not checked?(lv, key), do: tick(lv, key)
    apply(lv)
    assert status(run) == "applied"
    lv
  end

  describe "who sees the button" do
    test "a person who may edit the draft, with the AI on and an endpoint chosen", ctx do
      lv = open!(ctx)
      assert has_element?(lv, "#inventory-ai-open")

      lv |> element("#inventory-ai-open") |> render_click()
      assert has_element?(lv, "#inventory-ai-panel")
      assert has_element?(lv, "#inventory-ai-upload")
      assert has_element?(lv, "#inventory-ai-run[disabled]")
      assert has_element?(lv, "#inventory-ai-privacy")
    end

    test "the panel takes no room on the Items tab while it has nothing to show", ctx do
      lv = open!(ctx)
      refute has_element?(lv, "#inventory-ai-area")

      lv |> element("#inventory-ai-open") |> render_click()
      assert has_element?(lv, "#inventory-ai-area #inventory-ai-panel")
    end

    test "the list of batches keeps the state a person opened it in through an update", ctx do
      run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])
      lv = open!(ctx)

      assert has_element?(lv, "details#inventory-ai-runs[phx-mounted*=ignore_attrs]")
    end

    test "not without an endpoint", ctx do
      :ok = Settings.set_endpoint_uuid(nil)
      refute has_element?(open!(ctx), "#inventory-ai-open")
    end

    test "not while the AI module is off", ctx do
      {:ok, _} = PhoenixKitAI.disable_system()
      refute has_element?(open!(ctx), "#inventory-ai-open")
    end

    test "not on a posted stocktake", ctx do
      {:ok, _} = Inventories.post_document(ctx.doc, ctx.admin.uuid)
      refute has_element?(open!(ctx), "#inventory-ai-open")
    end

    test "a person with only the warehouse permission sees it and may use it", ctx do
      user = role_user!("warehouse")
      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])

      {:ok, lv, _html} = live(log_in(ctx.conn, user), items_path(ctx.doc))
      assert has_element?(lv, "#inventory-ai-open")

      open_run(lv, run)
      apply(lv)
      assert status(run) == "applied"
      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 480)
    end

    test "a person with only another permission is kept out by the page itself", ctx do
      user = role_user!("ai")
      assert {:error, {:redirect, _}} = live(log_in(ctx.conn, user), items_path(ctx.doc))
    end

    test "without the right to edit the draft the button is absent and the events are refused",
         ctx do
      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])
      lv = open!(ctx) |> open_run(run)

      # The page lets in only those who may edit a draft; the panel checks
      # again on the server, so the flag is taken away here.
      :sys.replace_state(lv.pid, fn state ->
        update_in(state.socket.assigns.ai, &%{&1 | can_edit?: false})
      end)

      render_click(lv, "inventory_ai_apply", %{})
      render_click(lv, "inventory_ai_discard", %{"run" => run.uuid})
      render_click(lv, "inventory_ai_retry", %{"run" => run.uuid})
      render_click(lv, "inventory_ai_run", %{})

      assert status(run) == "proposed"
      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 500)
      assert [_one] = InventoryAI.list_runs(ctx.doc.uuid)
      refute has_element?(lv, "#inventory-ai-open")
      refute has_element?(lv, "#inventory-ai-runs")

      ai = :sys.get_state(lv.pid).socket.assigns.ai
      assert ai.error == "You may not change this stocktake."

      refute render_component(&InventoryAIPanel.open_button/1, ai: ai, doc: ctx.doc) =~
               "inventory-ai-open"

      assert render_component(&InventoryAIPanel.open_button/1,
               ai: %{ai | can_edit?: true},
               doc: ctx.doc
             ) =~ "inventory-ai-open"
    end

    test "the upload of the panel leaves the Files tab's own upload alone", ctx do
      lv = open!(ctx)
      %{uploads: uploads} = :sys.get_state(lv.pid).socket.assigns
      assert Map.has_key?(uploads, :media_files)
      assert Map.has_key?(uploads, :inventory_ai_photos)
      assert uploads.media_files.max_entries == 10
      assert uploads.inventory_ai_photos.max_entries == Settings.max_photos()

      render_patch(lv, Routes.path("/admin/warehouse/inventory/#{ctx.doc.uuid}/files"))
      {:ok, folder} = StorageFolders.ensure_for_inventory(ctx.doc, ctx.admin.uuid)
      send(lv.pid, {:files_folder_result, {:ok, folder}})
      assert has_element?(lv, "#media-browser-inventory-#{ctx.doc.uuid}")

      render_patch(lv, items_path(ctx.doc))
      lv |> element("#inventory-ai-open") |> render_click()
      assert render_upload(photo_input(lv), "shelf.jpg") =~ "100%"
      refute has_element?(lv, "#inventory-ai-run[disabled]")
    end
  end

  describe "the upload's events" do
    test "removing an upload the panel does not have leaves the page alive", ctx do
      lv = open!(ctx)
      lv |> element("#inventory-ai-open") |> render_click()
      assert render_upload(photo_input(lv), "shelf.jpg") =~ "100%"
      [entry] = :sys.get_state(lv.pid).socket.assigns.uploads.inventory_ai_photos.entries

      render_click(lv, "inventory_ai_cancel_upload", %{"ref" => entry.ref})
      render_click(lv, "inventory_ai_cancel_upload", %{"ref" => entry.ref})
      render_click(lv, "inventory_ai_cancel_upload", %{"ref" => %{"x" => 1}})

      assert has_element?(lv, "#inventory-ai-panel")
      refute has_element?(lv, "#inventory-ai-entry-#{entry.ref}")
    end

    test "Propose without photos asks for them", ctx do
      lv = open!(ctx)
      lv |> element("#inventory-ai-open") |> render_click()

      assert render_click(lv, "inventory_ai_run", %{}) =~ "Upload the photos of the place first."
    end

    test "crafted values of the panel's fields are refused, the page stays", ctx do
      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])
      lv = open!(ctx) |> open_run(run)

      for {event, params} <- [
            {"inventory_ai_row", %{"row" => %{"a" => 1}}},
            {"inventory_ai_check", %{"row" => ["1"]}},
            {"inventory_ai_choose", %{"row" => "1", "no" => %{}}},
            {"inventory_ai_pick", %{"row" => %{}}},
            {"inventory_ai_unmerge", %{"row" => nil}},
            {"inventory_ai_change", %{"place" => %{"a" => "b"}}},
            {"inventory_ai_run", %{"place" => ["x"], "catalogue_uuids" => %{}}}
          ] do
        render_click(lv, event, params)
        assert has_element?(lv, "#inventory-ai-proposal-#{run.uuid}"), event
      end

      assert status(run) == "proposed"
    end
  end

  describe "a batch from the upload to the proposal" do
    # The photo is made with ImageMagick.
    @describetag :imagemagick
    # Storage says it cannot queue the variants: there is no Oban in the suite.
    @describetag :capture_log

    test "the photo goes to the document's folder, the AI is asked once, the proposal opens",
         ctx do
      InventoryAIStub.install()
      local_bucket!()
      InventoryAIStub.answer(answer([object(%{"catalogue_no" => 1, "loose_units" => 480})]))
      :ok = InventoryAI.subscribe(ctx.doc.uuid)

      lv = open!(ctx)
      lv |> element("#inventory-ai-open") |> render_click()

      assert render_upload(jpeg_input(lv), "shelf.jpg") =~ "100%"

      lv
      |> form("#inventory-ai-upload-form", %{
        "place" => "Shelf 2",
        "catalogue_uuids" => [ctx.catalogue.uuid]
      })
      |> render_change()

      refute has_element?(lv, "#inventory-ai-run[disabled]")
      lv |> form("#inventory-ai-upload-form") |> render_submit()

      assert_receive {:ai_request, body}, 5_000
      [%{"content" => [%{"text" => text} | images]}] = body["messages"]
      assert length(images) == 1
      assert text =~ "CATALOGUE\n★1|Hinge|H-1|piece|Fittings\n2|Screw|S-1|piece|Fittings"

      assert_receive {:inventory_ai_run, %{run_uuid: uuid, status: "proposed"}}, 5_000
      assert has_element?(lv, "#inventory-ai-proposal-#{uuid}")

      run = InventoryAI.get_run(ctx.doc.uuid, uuid)
      assert run.place_label == "Shelf 2"
      assert run.created_by_uuid == ctx.admin.uuid
      [photo_uuid] = run.photo_file_uuids
      folder = Inventories.get_document!(ctx.doc.uuid).storage_folder_uuid
      assert Storage.get_file(photo_uuid).folder_uuid == folder

      %{rows: [[type, user_uuid, source]]} =
        repo().query!(
          "SELECT request_type, user_uuid::text, metadata->>'source' FROM phoenix_kit_ai_requests ORDER BY inserted_at DESC LIMIT 1"
        )

      assert {type, user_uuid, source} ==
               {"vision", ctx.admin.uuid, "PhoenixKitWarehouse.InventoryAI"}

      apply(lv)
      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 480)
    end

    test "Propose takes the place and the catalogues it submits, without a change before",
         ctx do
      InventoryAIStub.install()
      local_bucket!()
      InventoryAIStub.answer(answer([object(%{"catalogue_no" => 1, "loose_units" => 480})]))
      other = catalogue!("Other")
      :ok = InventoryAI.subscribe(ctx.doc.uuid)

      lv = open!(ctx)
      lv |> element("#inventory-ai-open") |> render_click()
      assert render_upload(jpeg_input(lv), "shelf.jpg") =~ "100%"

      # Enter in the place field: the debounced change never reaches the server.
      lv
      |> form("#inventory-ai-upload-form", %{
        "place" => "Shelf 2",
        "catalogue_uuids" => [ctx.catalogue.uuid]
      })
      |> render_submit()

      assert_receive {:inventory_ai_run, %{run_uuid: uuid, status: "proposed"}}, 5_000
      run = InventoryAI.get_run(ctx.doc.uuid, uuid)
      assert run.place_label == "Shelf 2"
      assert run.result["catalogue_uuids"] == [ctx.catalogue.uuid]
      refute other.uuid in run.result["catalogue_uuids"]
    end

    test "a run refused before it starts keeps the uploads and stores no photo", ctx do
      local_bucket!()
      lv = open!(ctx)
      lv |> element("#inventory-ai-open") |> render_click()
      assert render_upload(jpeg_input(lv), "shelf.jpg") =~ "100%"

      # The endpoint was taken away after the page opened.
      :ok = Settings.set_endpoint_uuid(nil)
      html = lv |> form("#inventory-ai-upload-form", %{"place" => "A"}) |> render_submit()

      assert html =~ InventoryAI.error_message(:not_configured)
      assert has_element?(lv, "#inventory-ai-uploads li")
      assert InventoryAI.list_runs(ctx.doc.uuid) == []

      %{rows: [[stored]]} =
        repo().query!("SELECT count(*) FROM phoenix_kit_files WHERE user_uuid = $1", [
          Ecto.UUID.dump!(ctx.admin.uuid)
        ])

      assert stored == 0
    end
  end

  describe "photos stored for a run that was then refused" do
    # The photo is made with ImageMagick.
    @describetag :imagemagick
    # Storage says it cannot queue the variants: there is no Oban in the suite.
    @describetag :capture_log

    # Another tab starts a run after this page read the runs: Propose stores
    # the photo, then the run is refused.
    defp refused_after_store!(ctx) do
      local_bucket!()
      lv = open!(ctx)
      lv |> element("#inventory-ai-open") |> render_click()
      assert render_upload(jpeg_input(lv), "shelf.jpg") =~ "100%"

      other =
        %InventoryAIRun{}
        |> Ecto.Changeset.change(%{
          inventory_uuid: ctx.doc.uuid,
          location_uuid: ctx.location,
          photo_file_uuids: [Ecto.UUID.generate()],
          status: "running"
        })
        |> repo().insert!()

      html = lv |> form("#inventory-ai-upload-form", %{"place" => "A"}) |> render_submit()
      assert html =~ InventoryAI.error_message(:already_running)
      assert html =~ "The photos are kept in the Files tab"
      refute has_element?(lv, "#inventory-ai-uploads li")
      assert has_element?(lv, "#inventory-ai-stored")

      [stored] = :sys.get_state(lv.pid).socket.assigns.ai.stored_photos
      folder = Inventories.get_document!(ctx.doc.uuid).storage_folder_uuid
      assert Storage.get_file(stored).folder_uuid == folder

      {lv, stored, other}
    end

    test "Propose again sends them, without a new upload", ctx do
      InventoryAIStub.install()
      InventoryAIStub.answer(answer([object(%{"catalogue_no" => 1, "loose_units" => 480})]))
      :ok = InventoryAI.subscribe(ctx.doc.uuid)
      {lv, stored, other} = refused_after_store!(ctx)

      other |> Ecto.Changeset.change(status: "error") |> repo().update!()
      refute has_element?(lv, "#inventory-ai-run[disabled]")
      lv |> form("#inventory-ai-upload-form", %{"place" => "A"}) |> render_submit()

      assert_receive {:inventory_ai_run, %{run_uuid: uuid, status: "proposed"}}, 5_000
      assert InventoryAI.get_run(ctx.doc.uuid, uuid).photo_file_uuids == [stored]
      refute has_element?(lv, "#inventory-ai-stored")
    end

    test "Forget leaves them in the Files tab and sends them with no run", ctx do
      {lv, stored, _other} = refused_after_store!(ctx)

      lv |> element("#inventory-ai-forget-stored") |> render_click()

      refute has_element?(lv, "#inventory-ai-stored")
      assert has_element?(lv, "#inventory-ai-run[disabled]")
      assert Storage.get_file(stored)
      assert :sys.get_state(lv.pid).socket.assigns.ai.stored_photos == []
    end
  end

  describe "the proposal and Apply" do
    test "an alternative without a SKU shows no empty brackets", ctx do
      _bolt = item!(ctx.catalogue, %{name: "Bolt"})
      run = run!(ctx, "Shelf A", [object(%{"catalogue_no" => nil, "alternatives" => [1, 3]})])

      lv = open!(ctx) |> open_run(run)
      options = lv |> element("#inventory-ai-choose-1") |> render()

      assert options =~ "Hinge (H-1)"
      assert options =~ "Bolt"
      refute options =~ "()"
    end

    test "the Items header wraps: the buttons go under a long title on a narrow screen", ctx do
      lv = open!(ctx)
      assert has_element?(lv, "#inventory-items-header.flex-wrap")
      assert has_element?(lv, "#inventory-items-header h2.min-w-0.break-words")
    end

    test "the catalogues to narrow the photos to are checkboxes", ctx do
      lv = open!(ctx)
      lv |> element("#inventory-ai-open") |> render_click()

      assert has_element?(
               lv,
               ~s(#inventory-ai-catalogues input[type="checkbox"][name="catalogue_uuids[]"][value="#{ctx.catalogue.uuid}"])
             )

      refute has_element?(lv, "#inventory-ai-catalogues select")
    end

    test "a ticked catalogue stays ticked, and none ticked is every catalogue again", ctx do
      lv = open!(ctx)
      lv |> element("#inventory-ai-open") |> render_click()
      ticked = ~s(#inventory-ai-catalogues input[value="#{ctx.catalogue.uuid}"][checked])

      lv
      |> form("#inventory-ai-upload-form", %{"catalogue_uuids" => [ctx.catalogue.uuid]})
      |> render_change()

      assert has_element?(lv, ticked)

      # An unticked checkbox sends no key at all.
      render_change(lv, "inventory_ai_change", %{"place" => ""})
      refute has_element?(lv, ticked)
    end

    test "a seeded line is replaced, the others are not touched; the tab gets the written lines",
         ctx do
      stock!(ctx.screw, ctx.location, "40")
      doc = draft!(ctx.location)
      run = run!(ctx, "Shelf A", [object(%{"catalogue_no" => 1, "loose_units" => 480})], doc)

      lv = open!(ctx, doc) |> open_run(run)
      assert checked?(lv, 1)
      apply(lv)

      assert Decimal.eq?(counted(doc, ctx.hinge), 480)
      assert line(doc, ctx.hinge)["counted_by"] == "ai"
      assert line(doc, ctx.screw)["counted_by"] == "stock"
      assert Decimal.eq?(counted(doc, ctx.screw), 40)
      assert status(run) == "applied"
      refute has_element?(lv, "#inventory-ai-proposal-#{run.uuid}")

      # The tab's buffer and base are the written lines: a save passes and
      # writes the same lines.
      written = Inventories.get_document!(doc.uuid).lines
      html = render_click(lv, "save_draft", %{})
      refute html =~ "changed in another tab"
      assert Inventories.get_document!(doc.uuid).lines == written
    end

    test "a line marked seeded is replaced even when the stock changed since", ctx do
      stock!(ctx.hinge, ctx.location, "600")
      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 550})])

      lv = open!(ctx) |> open_run(run)
      assert render(lv) =~ "By the stock at seeding: 500, now 600"
      apply(lv)

      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 550)
    end

    test "an unmarked line equal to the stock is seeded; one that differs is manual: added, not ticked",
         ctx do
      equal =
        draft!(ctx.location, [%{"item_uuid" => ctx.hinge.uuid, "counted_quantity" => "500"}])

      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 490})], equal)
      apply_rows!(ctx, run, [1], equal)
      assert Decimal.eq?(counted(equal, ctx.hinge), 490)

      manual =
        draft!(ctx.location, [%{"item_uuid" => ctx.hinge.uuid, "counted_quantity" => "120"}])

      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 30})], manual)
      lv = open!(ctx, manual) |> open_run(run)
      refute checked?(lv, 1)
      assert render(lv) =~ "Counted by hand: 120"

      tick(lv, 1)
      apply(lv)
      assert Decimal.eq?(counted(manual, ctx.hinge), 150)
    end

    test "manual 120, place A gives 30: 150; A again gives 35: 155", ctx do
      doc =
        draft!(ctx.location, [
          %{"item_uuid" => ctx.hinge.uuid, "counted_quantity" => "120", "counted_by" => "manual"}
        ])

      first = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 30})], doc)
      apply_rows!(ctx, first, [1], doc)
      assert Decimal.eq?(counted(doc, ctx.hinge), 150)

      retake = run!(ctx, " a ", [object(%{"catalogue_no" => 1, "loose_units" => 35})], doc)
      lv = open!(ctx, doc) |> open_run(retake)
      assert has_element?(lv, "#inventory-ai-inputs-1 option[value=replace_part][selected]")
      # 155 against a stock of 500 is sharply below: not ticked by default.
      refute checked?(lv, 1)
      tick(lv, 1)
      apply(lv)

      assert Decimal.eq?(counted(doc, ctx.hinge), 155)
    end

    test "a second place adds; retaking A with A and B changes only A", ctx do
      first = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 100})])
      apply_rows!(ctx, first, [1])

      second = run!(ctx, "B", [object(%{"catalogue_no" => 1, "loose_units" => 50})])
      lv = open!(ctx) |> open_run(second)
      assert render(lv) =~ "Already 100: A 100"
      tick(lv, 1)
      apply(lv)
      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 150)

      retake = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 80})])
      apply_rows!(ctx, retake, [1])
      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 130)

      places = Enum.map(line(ctx.doc, ctx.hinge)["ai_parts"], & &1["place"])
      assert places == ["A", "B"]
    end

    test "two empty place labels are two places: they add up", ctx do
      first = run!(ctx, nil, [object(%{"catalogue_no" => 1, "loose_units" => 100})])
      apply_rows!(ctx, first, [1])

      second = run!(ctx, nil, [object(%{"catalogue_no" => 1, "loose_units" => 50})])
      lv = open!(ctx) |> open_run(second)
      assert has_element?(lv, "#inventory-ai-inputs-1 option[value=add_part][selected]")
      tick(lv, 1)
      apply(lv)

      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 150)
    end

    test "a quantity corrected in a row ticked by default is applied: the correction accepts it",
         ctx do
      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])
      lv = open!(ctx) |> open_run(run)
      assert checked?(lv, 1)

      set_inputs(lv, 1, %{"quantity" => "490"})
      assert checked?(lv, 1)
      apply(lv)

      assert status(run) == "applied"
      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 490)
    end

    test "a blank or unreadable quantity is an error of the field, never 0", ctx do
      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])
      lv = open!(ctx) |> open_run(run)

      for bad <- ["", "abc"] do
        set_inputs(lv, 1, %{"quantity" => bad})
        assert checked?(lv, 1) or tick(lv, 1)
        html = apply(lv)

        assert html =~ "Some ticked rows are not complete"
        assert html =~ "Enter the quantity as a number."
        assert status(run) == "proposed"
        assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 500)
      end
    end

    test "a row without an item: the item picker chooses one, a row of the same item merges, and back",
         ctx do
      run =
        run!(ctx, "A", [
          object(%{"catalogue_no" => 1, "loose_units" => 480}),
          object(%{"object_key" => "B", "catalogue_no" => nil, "loose_units" => 10})
        ])

      lv = open!(ctx) |> open_run(run)
      refute checked?(lv, 2)
      assert has_element?(lv, "#inventory-ai-check-2[disabled]")

      lv |> element("#inventory-ai-pick-2") |> render_click()
      send(lv.pid, {:item_picker_select, "inventory-ai-picker-#{run.uuid}-2", ctx.hinge})

      refute has_element?(lv, "#inventory-ai-row-2")
      assert has_element?(lv, "#inventory-ai-quantity-1[value='490']")
      assert has_element?(lv, "#inventory-ai-unmerge-1")

      lv |> element("#inventory-ai-unmerge-1") |> render_click()
      assert has_element?(lv, "#inventory-ai-row-2")
      assert has_element?(lv, "#inventory-ai-quantity-1[value='480']")

      lv |> element("#inventory-ai-pick-2") |> render_click()
      send(lv.pid, {:item_picker_select, "inventory-ai-picker-#{run.uuid}-2", ctx.hinge})
      apply(lv)

      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 490)
      assert [%{"merged_rows" => [2]}] = repo().get!(InventoryAIRun, run.uuid).decisions["rows"]
    end

    test "an item that is not active is refused by the picker's row", ctx do
      inactive = item!(ctx.catalogue, %{status: "inactive"})
      run = run!(ctx, "A", [object(%{"catalogue_no" => nil, "loose_units" => 10})])
      lv = open!(ctx) |> open_run(run)

      lv |> element("#inventory-ai-pick-1") |> render_click()
      send(lv.pid, {:item_picker_select, "inventory-ai-picker-#{run.uuid}-1", inactive})

      assert render(lv) =~ "This item is not active in the catalogue."
      assert has_element?(lv, "#inventory-ai-check-1[disabled]")
    end

    test "Apply twice, in one tab or in two: the second is refused", ctx do
      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])
      a = open!(ctx) |> open_run(run)
      b = open!(ctx) |> open_run(run)

      apply(a)
      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 480)

      # The other tab hears that the batch is closed.
      refute has_element?(b, "#inventory-ai-proposal-#{run.uuid}")
      assert render_click(b, "inventory_ai_apply", %{}) =~ "applied or discarded already"
      assert render_click(a, "inventory_ai_apply", %{}) =~ "applied or discarded already"
      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 480)
    end

    test "Apply from a tab whose lines are old is refused", ctx do
      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])
      a = open!(ctx)
      b = open!(ctx) |> open_run(run)

      render_change(a, "set_counted", %{"index" => "0", "counted_quantity" => "7"})
      render_click(a, "save_draft", %{})

      assert apply(b) =~ "changed in another tab"
      assert status(run) == "proposed"
      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 7)
    end

    test "a draft trashed after the page opened refuses Apply", ctx do
      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])
      lv = open!(ctx) |> open_run(run)
      {:ok, _} = Inventories.soft_delete_document(ctx.doc, ctx.admin.uuid)

      assert apply(lv) =~ "The document is in the trash."
      assert status(run) == "proposed"
      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 500)
    end

    test "a run of another document in an event is refused", ctx do
      other = draft!(ctx.location)
      foreign = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 1})], other)
      lv = open!(ctx)

      assert render_click(lv, "inventory_ai_open_run", %{"run" => foreign.uuid}) =~
               "belongs to another document"

      render_click(lv, "inventory_ai_discard", %{"run" => foreign.uuid})
      render_click(lv, "inventory_ai_retry", %{"run" => foreign.uuid})
      assert status(foreign) == "proposed"
    end

    test "the lines below the stock are summed up before Conduct", ctx do
      run = run!(ctx, "Shelf A", [object(%{"catalogue_no" => 1, "loose_units" => 300})])
      lv = apply_rows!(ctx, run, [1])

      assert has_element?(lv, "#inventory-ai-below-stock")
      assert render(lv) =~ "stock 500, counted 300 (Shelf A)"
    end
  end

  describe "the runs" do
    test "discard closes the proposal without writing", ctx do
      run = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])
      lv = open!(ctx) |> open_run(run)

      lv |> element("#inventory-ai-discard") |> render_click()

      assert status(run) == "discarded"
      refute has_element?(lv, "#inventory-ai-proposal-#{run.uuid}")
      assert Decimal.eq?(counted(ctx.doc, ctx.hinge), 500)
    end

    test "retry closes the failed run as replaced and starts the photos again", ctx do
      # The retry checks again that the photos are files of the document.
      failed =
        run!(ctx, "A", [])
        |> Ecto.Changeset.change(
          status: "error",
          error: "x",
          photo_file_uuids: photos!(ctx.doc, ctx.admin, 1)
        )
        |> repo().update!()

      :ok = InventoryAI.subscribe(ctx.doc.uuid)
      lv = open!(ctx)

      lv |> element("#inventory-ai-retry-#{failed.uuid}") |> render_click()

      closed = repo().get!(InventoryAIRun, failed.uuid)
      assert closed.status == "discarded"
      assert closed.decisions["discarded"]["reason"] == "retried"
      new_uuid = closed.decisions["discarded"]["replaced_by_run_uuid"]
      assert repo().get!(InventoryAIRun, new_uuid).photo_file_uuids == failed.photo_file_uuids

      # The files hold no bytes: the new run fails on its own, without a call.
      assert_receive {:inventory_ai_run, %{run_uuid: ^new_uuid, status: "error"}}, 5_000
    end

    test "a late answer does not change the status; shown by hand it is the proposal", ctx do
      answer = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 42})])

      failed =
        answer
        |> Ecto.Changeset.change(
          status: "error",
          error: "interrupted",
          late_result: %{
            "result" => answer.result,
            "catalogue_map" => answer.catalogue_map,
            "photo_file_uuids" => answer.photo_file_uuids,
            "model" => "test/late"
          },
          result: nil
        )
        |> repo().update!()

      lv = open!(ctx)
      assert status(failed) == "error"
      assert has_element?(lv, "#inventory-ai-late-#{failed.uuid}")
      refute has_element?(lv, "#inventory-ai-late-warning-#{failed.uuid}")

      lv |> element("#inventory-ai-late-#{failed.uuid}") |> render_click()
      assert status(failed) == "proposed"
      assert has_element?(lv, "#inventory-ai-proposal-#{failed.uuid}")
    end

    test "a late answer after newer runs warns that the place may be read again", ctx do
      answer = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 42})])

      failed =
        answer
        |> Ecto.Changeset.change(
          status: "error",
          inserted_at: ~U[2026-01-01 10:00:00Z],
          late_result: %{"result" => answer.result, "catalogue_map" => answer.catalogue_map}
        )
        |> repo().update!()

      _newer = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 40})])

      assert has_element?(open!(ctx), "#inventory-ai-late-warning-#{failed.uuid}")
    end
  end

  describe "the warehouse change and the posting" do
    test "the warehouse change warns of the photo lines and closes the open runs", ctx do
      {:ok, type} =
        Locations.create_location_type(%{name: "WH #{System.unique_integer([:positive])}"})

      [site_a, site_b] =
        for name <- ["Site A", "Site B"] do
          {:ok, loc} = Locations.create_location(%{name: name, status: "active"})
          Locations.sync_location_types(loc.uuid, [type.uuid])
          loc
        end

      StockLedger.set_warehouse_location_type_uuid(type.uuid)
      stock!(ctx.hinge, site_a.uuid, "500")
      doc = draft!(site_a.uuid)

      applied = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})], doc)
      apply_rows!(ctx, applied, [1], doc)
      open_run = run!(ctx, "B", [object(%{"catalogue_no" => 1, "loose_units" => 5})], doc)

      {:ok, lv, _} = live(ctx.conn, Routes.path("/admin/warehouse/inventory/#{doc.uuid}"))

      lv
      |> element("form[phx-change='set_location']")
      |> render_change(%{"location_uuid" => site_b.uuid})

      assert has_element?(lv, "#inventory-ai-location-warning")
      assert render(lv) =~ "1 line counted from photos will be lost."

      render_click(lv, "confirm_location_change", %{})

      assert Inventories.get_document!(doc.uuid).location_uuid == site_b.uuid
      assert status(open_run) == "discarded"
      assert status(applied) == "applied"
    end

    test "conducting keeps the photo keys and closes the open runs", ctx do
      applied = run!(ctx, "A", [object(%{"catalogue_no" => 1, "loose_units" => 480})])
      apply_rows!(ctx, applied, [1])
      open_run = run!(ctx, "B", [object(%{"catalogue_no" => 1, "loose_units" => 5})])

      lv = open!(ctx)
      assert has_element?(lv, "#inventory-ai-open-runs")
      render_click(lv, "post", %{})

      posted = Inventories.get_document!(ctx.doc.uuid)
      assert posted.status == "posted"
      hinge = Enum.find(posted.lines, &(&1["item_uuid"] == ctx.hinge.uuid))
      assert hinge["counted_by"] == "ai"
      assert [%{"place" => "A"}] = hinge["ai_parts"]
      assert hinge["ai_basis"] =~ "A:"
      assert status(open_run) == "discarded"
    end
  end
end
