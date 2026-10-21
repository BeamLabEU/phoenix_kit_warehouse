defmodule PhoenixKitWarehouse.InventoryAI.RunsTest do
  # A run from start to its outcome (spec §6.1, §6.4, §10.3): the call, the
  # checks of the answer, one running run per document, the late answer,
  # discard, retry, interrupted and stale runs. The AI is a Req.Test stub.
  use PhoenixKitWarehouse.DataCase, async: false

  # The photos are made with ImageMagick (the fixture is a small JPEG).
  @moduletag :imagemagick

  import ExUnit.CaptureLog
  import PhoenixKitWarehouse.Test.InventoryAIFixtures

  alias PhoenixKit.Activity
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FolderLink
  alias PhoenixKitWarehouse.InventoryAI
  alias PhoenixKitWarehouse.InventoryAI.Prompt
  alias PhoenixKitWarehouse.InventoryAI.Runner
  alias PhoenixKitWarehouse.InventoryAI.Settings
  alias PhoenixKitWarehouse.InventoryAIRun
  alias PhoenixKitWarehouse.StorageFolders
  alias PhoenixKitWarehouse.Test.InventoryAIStub, as: Stub

  setup do
    Stub.install()
    endpoint = ai_ready!()
    user = user!()
    location = Ecto.UUID.generate()
    catalogue = catalogue!("Fittings")
    hinge = item!(catalogue, %{name: "Hinge 110", sku: "H-110"})
    screw = item!(catalogue, %{name: "Screw 4x30", sku: "S-430"})
    stock!(screw, location, "512")
    doc = draft!(location)
    photos = photos!(doc, user)
    :ok = InventoryAI.subscribe(doc.uuid)

    %{
      endpoint: endpoint,
      user: user,
      location: location,
      catalogue: catalogue,
      hinge: hinge,
      screw: screw,
      doc: doc,
      photos: photos
    }
  end

  defp attrs(ctx, extra \\ %{}) do
    Map.merge(
      %{
        "place_label" => "Shelf 2, top",
        "photo_file_uuids" => ctx.photos,
        "catalogue_uuids" => [ctx.catalogue.uuid]
      },
      extra
    )
  end

  defp start!(ctx, extra \\ %{}, opts \\ []) do
    opts = Keyword.merge([locale: "en", retrieve: retriever()], opts)
    {:ok, run, pid} = InventoryAI.start_run(ctx.doc, attrs(ctx, extra), ctx.user, opts)
    {run, pid}
  end

  defp await(run) do
    uuid = run.uuid
    assert_receive {:inventory_ai_run, %{run_uuid: ^uuid, late: false} = message}, 5_000

    InventoryAI.get_run(run.inventory_uuid, uuid)
    |> tap(fn reloaded -> assert reloaded.status == message.status end)
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  describe "a run that comes back" do
    test "asks once, as the spec says, and leaves a proposal", ctx do
      Stub.answer(
        answer([
          object(%{
            "catalogue_no" => 2,
            "closed_packages" => 2,
            "open_packages" => 1,
            "units_per_package" => 100,
            "loose_units" => nil
          }),
          object(%{"object_key" => "B", "catalogue_no" => 1, "loose_units" => 4})
        ])
      )

      {run, _pid} = start!(ctx)
      assert run.status == "running"
      assert run.created_by_uuid == ctx.user.uuid
      assert run.location_uuid == ctx.location
      assert run.endpoint_uuid == ctx.endpoint.uuid

      assert_receive {:ai_request, body}, 5_000
      run = await(run)

      # The call (§6.1): max_tokens, no temperature, the strict schema.
      assert body["max_tokens"] == 24_000
      refute Map.has_key?(body, "temperature")
      assert body["response_format"]["type"] == "json_schema"
      assert body["response_format"]["json_schema"]["name"] == "inventory_count"
      assert body["response_format"]["json_schema"]["strict"] == true

      [%{"content" => [%{"type" => "text", "text" => text} | images]}] = body["messages"]
      assert length(images) == 2

      assert Enum.all?(
               images,
               &String.starts_with?(&1["image_url"]["url"], "data:image/jpeg;base64,")
             )

      assert text =~ "You count stock on photos"
      assert text =~ "LANGUAGE: en"

      assert text =~
               "CATALOGUE\n1|Hinge 110|H-110|piece|Fittings\n★2|Screw 4x30|S-430|piece|Fittings"

      refute text =~ "512"

      # The run.
      assert run.status == "proposed"
      assert run.model == "test/vision-model"
      assert run.prompt_uuid == Settings.prompt_uuid()
      assert run.catalogue_map == %{"1" => ctx.hinge.uuid, "2" => ctx.screw.uuid}
      assert run.error == nil

      [screws, hinges] = run.result["rows"]
      assert screws["item"]["item_uuid"] == ctx.screw.uuid
      assert screws["count"]["kind"] == "counted"
      assert Decimal.equal?(Decimal.new(screws["count"]["quantity"]), 235)
      assert hinges["item"]["item_uuid"] == ctx.hinge.uuid
      assert run.result["catalogue_uuids"] == [ctx.catalogue.uuid]
      assert run.result["nothing_found"] == false
    end

    test "the journal row of the call: vision, the source, the user, the key", ctx do
      Stub.answer(answer([object()]))
      {run, _pid} = start!(ctx)
      _ = await(run)

      %{rows: [[type, user_uuid, source, key]]} =
        Repo.query!(
          "SELECT request_type, user_uuid::text, metadata->>'source', metadata->>'idempotency_key' FROM phoenix_kit_ai_requests ORDER BY inserted_at DESC LIMIT 1"
        )

      assert type == "vision"
      assert user_uuid == ctx.user.uuid
      assert source == "PhoenixKitWarehouse.InventoryAI"
      assert key == "inventory:#{ctx.doc.uuid}:#{run.uuid}"
    end

    test "the prompt's usage is counted and the proposal is journalled", ctx do
      Stub.answer(answer([object()]))
      {run, _pid} = start!(ctx)
      run = await(run)

      assert PhoenixKitAI.get_prompt(run.prompt_uuid).usage_count == 1

      assert [entry] =
               Activity.list(
                 action: "warehouse.inventory.ai_proposed",
                 resource_uuid: ctx.doc.uuid
               ).entries

      assert entry.metadata["run_uuid"] == run.uuid
      assert entry.metadata["photo_count"] == 2
      assert entry.metadata["model"] == "test/vision-model"
      assert entry.actor_uuid == ctx.user.uuid
    end

    test "a photo that cannot be read is skipped; the numbering is of those left", ctx do
      Stub.answer(answer([object()]))
      [missing, kept] = ctx.photos

      {run, _pid} =
        start!(ctx, %{"photo_file_uuids" => [missing, kept]},
          retrieve: retriever(%{missing => :missing})
        )

      assert_receive {:ai_request, body}, 5_000
      run = await(run)

      [%{"content" => [_text | images]}] = body["messages"]
      assert length(images) == 1
      assert run.photo_file_uuids == [kept]
      assert [%{"file_uuid" => ^missing}] = run.result["skipped_photos"]
    end

    test "nothing found is a proposal without rows, not an error", ctx do
      Stub.answer(answer([], %{"nothing_found" => true}))
      {run, _pid} = start!(ctx)
      run = await(run)

      assert run.status == "proposed"
      assert run.result["rows"] == []
      assert run.result["nothing_found"] == true
    end
  end

  describe "a run that fails" do
    test "an answer cut off inside its JSON says to send fewer photos", ctx do
      Stub.answer_text(
        ~s({"off_purpose": {"flag": false, "reason": ""}, "objects": [{"object_key": "A", "pho)
      )

      {run, _pid} = start!(ctx)
      run = await(run)

      assert run.status == "error"
      assert run.error == InventoryAI.error_message(:truncated)
      assert run.error =~ "fewer photos"
    end

    test "photos off purpose: an error with the model's reason, no proposal", ctx do
      Stub.answer(
        answer([object()], %{
          "off_purpose" => %{"flag" => true, "reason" => "A screenshot of a chat"}
        })
      )

      {run, _pid} = start!(ctx)
      run = await(run)

      assert run.status == "error"
      assert run.error =~ "A screenshot of a chat"
      assert run.result["rows"] == nil
    end

    test "an answer that is not an object", ctx do
      Stub.answer_text("[1, 2]")
      {run, _pid} = start!(ctx)
      run = await(run)

      assert run.status == "error"
      assert run.error == InventoryAI.error_message(:not_an_object)
    end

    test "the provider's error, in ai's words", ctx do
      Stub.fail(401)
      {run, _pid} = start!(ctx)
      run = await(run)

      assert run.status == "error"
      assert run.error == PhoenixKitAI.Errors.message(:invalid_api_key)
    end

    test "a switched-off prompt: an error, and no call", ctx do
      {:ok, prompt} = Prompt.ensure()
      {:ok, _} = PhoenixKitAI.update_prompt(prompt, %{enabled: false})
      Stub.answer(answer([object()]))

      {run, _pid} = start!(ctx)
      run = await(run)

      assert run.status == "error"
      assert run.error == PhoenixKitAI.Errors.message({:prompt_error, :disabled})
      refute_received {:ai_request, _}
    end

    test "no photo can be read: an error, and no call", ctx do
      Stub.answer(answer([object()]))
      [a] = photos!(ctx.doc, ctx.user, 1)

      {run, _pid} =
        start!(ctx, %{"photo_file_uuids" => [a]}, retrieve: retriever(%{a => :missing}))

      run = await(run)

      assert run.status == "error"
      assert run.error == InventoryAI.error_message(:no_photos)
      refute_received {:ai_request, _}
    end

    test "a crash in the task closes the run as error at once", ctx do
      {:ok, run, _pid} =
        InventoryAI.start_run(ctx.doc, attrs(ctx), ctx.user,
          locale: "en",
          retrieve: fn _uuid -> raise "the storage is gone" end
        )

      # The photos' own rescue turns that into "no photos"; a crash of the
      # task body itself is driven straight through Runner.run/1:
      _ = await(run)

      {:ok, crashing} =
        %InventoryAIRun{}
        |> Ecto.Changeset.change(%{
          inventory_uuid: ctx.doc.uuid,
          location_uuid: ctx.location,
          status: "running"
        })
        |> Repo.insert()

      context = Runner.context(crashing, locale: "en") |> Map.put(:photo_file_uuids, :not_a_list)
      log = capture_log(fn -> assert Runner.run(context) == :ok end)
      assert log =~ "crashed"

      reloaded = InventoryAI.get_run(ctx.doc.uuid, crashing.uuid)
      assert reloaded.status == "error"
      assert reloaded.error == InventoryAI.error_message(:interrupted)
    end
  end

  describe "the log of a failed task" do
    test "a crash names its kind and where, never the values it held", ctx do
      {:ok, crashing} =
        %InventoryAIRun{}
        |> Ecto.Changeset.change(%{
          inventory_uuid: ctx.doc.uuid,
          location_uuid: ctx.location,
          status: "running"
        })
        |> Repo.insert()

      context =
        Runner.context(crashing, locale: "en")
        |> Map.put(:photo_file_uuids, {:api_key, "sk-SECRET-123"})

      log = capture_log(fn -> assert Runner.run(context) == :ok end)

      assert log =~ "crashed"
      assert log =~ "Protocol.UndefinedError"
      refute log =~ "sk-SECRET-123"
      assert InventoryAI.get_run(ctx.doc.uuid, crashing.uuid).status == "error"
    end

    test "an exit (a pool, a GenServer.call) closes the run as error at once", ctx do
      Req.Test.stub(Stub, fn _conn ->
        exit({:timeout, {GenServer, :call, [:pool, %{api_key: "sk-SECRET-123"}]}})
      end)

      log =
        capture_log(fn ->
          {run, pid} = start!(ctx)
          await_down(pid)
          send(self(), {:run, InventoryAI.get_run(ctx.doc.uuid, run.uuid)})
        end)

      assert_received {:run, run}
      assert run.status == "error"
      assert run.error == InventoryAI.error_message(:interrupted)
      assert log =~ "exited"
      assert log =~ ":timeout"
      refute log =~ "sk-SECRET-123"
    end
  end

  test "the size of too large photos is rounded up, so it never reads as the limit" do
    message = InventoryAI.error_message({:too_large, 80_500_000, 80_000_000})
    assert message =~ "81 MB"
    assert message =~ "at most 80 MB"
  end

  test "the endpoint the task declaration names is the one chosen", ctx do
    assert InventoryAI.endpoint_uuids() == [ctx.endpoint.uuid]
  end

  describe "start_run/4 refuses" do
    test "while the AI module is off", ctx do
      {:ok, _} = PhoenixKitAI.disable_system()
      assert InventoryAI.start_run(ctx.doc, attrs(ctx), ctx.user) == {:error, :ai_disabled}
    end

    test "without an endpoint", ctx do
      :ok = Settings.set_endpoint_uuid("")
      assert InventoryAI.start_run(ctx.doc, attrs(ctx), ctx.user) == {:error, :not_configured}
    end

    test "without photos, or with more than the setting allows", ctx do
      assert InventoryAI.start_run(ctx.doc, attrs(ctx, %{"photo_file_uuids" => []}), ctx.user) ==
               {:error, :no_photos}

      :ok = Settings.set_max_photos(1)

      assert InventoryAI.start_run(ctx.doc, attrs(ctx), ctx.user) ==
               {:error, {:too_many_photos, 2, 1}}
    end

    test "a place longer than 200 characters", ctx do
      assert InventoryAI.start_run(
               ctx.doc,
               attrs(ctx, %{"place_label" => String.duplicate("x", 201)}),
               ctx.user
             ) ==
               {:error, :place_too_long}
    end

    test "a catalogue larger than max_items", ctx do
      :ok = Settings.set_max_items(1)

      assert InventoryAI.start_run(ctx.doc, attrs(ctx), ctx.user) ==
               {:error, {:too_many_items, 2, 1}}
    end

    test "a document that is not a live draft", ctx do
      {:ok, trashed} = PhoenixKitWarehouse.Inventories.soft_delete_document(ctx.doc, nil)
      assert InventoryAI.start_run(trashed, attrs(ctx), ctx.user) == {:error, :deleted}

      posted = draft!(ctx.location)
      {:ok, _} = PhoenixKitWarehouse.Inventories.post_document(posted, ctx.user.uuid)
      assert InventoryAI.start_run(posted, attrs(ctx), ctx.user) == {:error, :not_draft}
    end

    test "photos that are not files of this document's folder", ctx do
      other = draft!(ctx.location)
      foreign = photos!(other, ctx.user, 1)
      loose = storage_file!(nil, ctx.user).uuid

      for photos <- [foreign, [loose], [Ecto.UUID.generate()], ["nope"], [hd(ctx.photos), nil]] do
        assert InventoryAI.start_run(
                 ctx.doc,
                 attrs(ctx, %{"photo_file_uuids" => photos}),
                 ctx.user
               ) ==
                 {:error, :invalid_photos}
      end

      # A document without a folder has no photos at all.
      bare = draft!(ctx.location)

      assert InventoryAI.start_run(bare, attrs(ctx, %{"photo_file_uuids" => [loose]}), ctx.user) ==
               {:error, :invalid_photos}

      assert InventoryAI.list_runs(ctx.doc.uuid) == []
      refute_received {:ai_request, _}
    end

    test "a file linked into the document's folder is one of its photos", ctx do
      Stub.answer(answer([object()]))
      linked = storage_file!(nil, ctx.user)

      {:ok, folder} =
        StorageFolders.ensure_for_inventory(ctx.doc, ctx.user.uuid)

      %FolderLink{}
      |> FolderLink.changeset(%{
        folder_uuid: folder.uuid,
        file_uuid: linked.uuid
      })
      |> Repo.insert!()

      {run, _pid} = start!(ctx, %{"photo_file_uuids" => [linked.uuid]})
      assert run.photo_file_uuids == [linked.uuid]
      assert await(run).status == "proposed"
    end

    test "the same photo twice is sent once", ctx do
      Stub.answer(answer([object()]))
      [photo | _] = ctx.photos
      :ok = Settings.set_max_photos(1)

      {run, _pid} = start!(ctx, %{"photo_file_uuids" => [photo, photo]})
      assert run.photo_file_uuids == [photo]

      assert_receive {:ai_request, body}, 5_000
      [%{"content" => [_text | images]}] = body["messages"]
      assert length(images) == 1
      _ = await(run)
    end

    test "catalogues that are not uuids", ctx do
      assert InventoryAI.start_run(
               ctx.doc,
               attrs(ctx, %{"catalogue_uuids" => [ctx.catalogue.uuid, "nope"]}),
               ctx.user
             ) == {:error, :invalid_catalogues}
    end

    test "no run is left behind by a refusal", ctx do
      :ok = Settings.set_max_items(1)
      {:error, _} = InventoryAI.start_run(ctx.doc, attrs(ctx), ctx.user)
      assert InventoryAI.list_runs(ctx.doc.uuid) == []
    end
  end

  describe "one running run per document" do
    test "a second start while the first is asking is refused", ctx do
      Stub.answer_when_released(answer([object()]))
      {run, _pid} = start!(ctx)
      assert_receive {:ai_waiting, stub}, 5_000

      assert InventoryAI.start_run(ctx.doc, attrs(ctx), ctx.user, retrieve: retriever()) ==
               {:error, :already_running}

      send(stub, :go)
      assert await(run).status == "proposed"

      # Another document is not held up.
      other = draft!(ctx.location)
      Stub.answer(answer([object()]))

      {:ok, other_run, pid} =
        InventoryAI.start_run(
          other,
          attrs(ctx, %{"photo_file_uuids" => photos!(other, ctx.user)}),
          ctx.user,
          retrieve: retriever()
        )

      await_down(pid)
      assert InventoryAI.get_run(other.uuid, other_run.uuid).status == "proposed"
    end
  end

  describe "the late answer" do
    test "a discarded run keeps the answer that came after, and stays discarded", ctx do
      Stub.answer_when_released(answer([object()]))
      {run, pid} = start!(ctx)
      assert_receive {:ai_waiting, stub}, 5_000

      assert {:ok, %{status: "discarded"}} =
               InventoryAI.discard_run(run, ctx.user, inventory_uuid: ctx.doc.uuid)

      send(stub, :go)
      uuid = run.uuid
      assert_receive {:inventory_ai_run, %{run_uuid: ^uuid, late: true}}, 5_000
      await_down(pid)

      reloaded = InventoryAI.get_run(ctx.doc.uuid, run.uuid)
      assert reloaded.status == "discarded"
      assert [_row] = reloaded.late_result["result"]["rows"]
      assert reloaded.late_result["model"] == "test/vision-model"
      assert reloaded.result["rows"] == nil
    end

    test "an interrupted run keeps the late answer, and stays an error", ctx do
      Stub.answer_when_released(answer([object()]))
      {run, pid} = start!(ctx)
      assert_receive {:ai_waiting, stub}, 5_000

      assert InventoryAI.interrupt_run(run) == :ok
      send(stub, :go)
      await_down(pid)

      reloaded = InventoryAI.get_run(ctx.doc.uuid, run.uuid)
      assert reloaded.status == "error"
      assert reloaded.error == InventoryAI.error_message(:interrupted)
      assert [_row] = reloaded.late_result["result"]["rows"]
    end

    test "interrupting a run that has finished does nothing", ctx do
      Stub.answer(answer([object()]))
      {run, _pid} = start!(ctx)
      run = await(run)

      assert InventoryAI.interrupt_run(run.uuid) == :noop
      assert InventoryAI.get_run(ctx.doc.uuid, run.uuid).status == "proposed"
    end
  end

  describe "stale runs" do
    defp age!(run, seconds) do
      past = DateTime.add(DateTime.utc_now(), -seconds, :second) |> DateTime.truncate(:second)

      {1, _} =
        Repo.update_all(from(r in InventoryAIRun, where: r.uuid == ^run.uuid),
          set: [inserted_at: past]
        )
    end

    defp running!(ctx) do
      %InventoryAIRun{}
      |> Ecto.Changeset.change(%{
        inventory_uuid: ctx.doc.uuid,
        location_uuid: ctx.location,
        status: "running"
      })
      |> Repo.insert!()
    end

    test "a run running for more than 10 minutes is an error when the runs are listed", ctx do
      old = running!(ctx)
      age!(old, 11 * 60)

      assert [listed] = InventoryAI.list_runs(ctx.doc.uuid)
      assert listed.status == "error"
      assert listed.error == InventoryAI.error_message(:interrupted)
    end

    test "a younger one is left running", ctx do
      young = running!(ctx)
      age!(young, 9 * 60)

      assert [%{status: "running"}] = InventoryAI.list_runs(ctx.doc.uuid)
    end

    test "the list leaves out the answer, the catalogue and the late answer; get_run has them",
         ctx do
      run = running!(ctx)

      {1, _} =
        Repo.update_all(from(r in InventoryAIRun, where: r.uuid == ^run.uuid),
          set: [
            status: "error",
            result: %{"rows" => [%{"no" => 1}]},
            catalogue_map: %{"1" => %{"item_uuid" => Ecto.UUID.generate()}},
            late_result: %{"result" => %{"rows" => []}}
          ]
        )

      bare = running!(ctx) |> Ecto.Changeset.change(status: "error") |> Repo.update!()

      listed = Map.new(InventoryAI.list_runs(ctx.doc.uuid), &{&1.uuid, &1})

      assert listed[run.uuid].status == "error"
      assert is_nil(listed[run.uuid].result)
      assert listed[run.uuid].catalogue_map == %{}
      assert is_nil(listed[run.uuid].late_result)
      assert listed[run.uuid].late_answer?
      refute listed[bare.uuid].late_answer?

      full = InventoryAI.get_run(ctx.doc.uuid, run.uuid)
      assert full.result == %{"rows" => [%{"no" => 1}]}
      assert full.late_result == %{"result" => %{"rows" => []}}
    end

    test "and before a new run on the document", ctx do
      old = running!(ctx)
      age!(old, 11 * 60)
      Stub.answer(answer([object()]))

      {run, _pid} = start!(ctx)
      _ = await(run)

      assert InventoryAI.get_run(ctx.doc.uuid, old.uuid).status == "error"
    end
  end

  describe "discard and retry" do
    test "retry starts the photos again and closes the failed run as replaced", ctx do
      Stub.fail(401)
      {failed, _pid} = start!(ctx)
      failed = await(failed)
      assert failed.status == "error"

      Stub.answer(answer([object()]))

      {:ok, retried, _pid} =
        InventoryAI.retry_run(failed, ctx.user,
          inventory_uuid: ctx.doc.uuid,
          retrieve: retriever()
        )

      assert_receive {:inventory_ai_run, %{run_uuid: uuid, status: "discarded"}}
                     when uuid == failed.uuid

      retried = await(retried)
      assert retried.status == "proposed"
      assert retried.photo_file_uuids == failed.photo_file_uuids
      assert retried.place_label == failed.place_label
      assert retried.result["catalogue_uuids"] == [ctx.catalogue.uuid]

      closed = InventoryAI.get_run(ctx.doc.uuid, failed.uuid)
      assert closed.status == "discarded"
      assert closed.decisions["discarded"]["reason"] == "retried"
      assert closed.decisions["discarded"]["replaced_by_run_uuid"] == retried.uuid
      assert closed.decisions["discarded"]["by_uuid"] == ctx.user.uuid
    end

    test "only a failed run can be retried, and nothing is started otherwise", ctx do
      Stub.answer(answer([object()]))
      {run, _pid} = start!(ctx)
      run = await(run)

      assert InventoryAI.retry_run(run, ctx.user,
               inventory_uuid: ctx.doc.uuid,
               retrieve: retriever()
             ) == {:error, :not_error}

      assert [%{uuid: uuid}] = InventoryAI.list_runs(ctx.doc.uuid)
      assert uuid == run.uuid
    end

    test "a run is discarded or retried only through its own document", ctx do
      Stub.fail(401)
      {failed, _pid} = start!(ctx)
      failed = await(failed)
      assert_received {:ai_request, _}
      other = draft!(ctx.location)

      for opts <- [[inventory_uuid: other.uuid], []] do
        assert InventoryAI.discard_run(failed, ctx.user, opts) == {:error, :wrong_document}

        assert InventoryAI.retry_run(failed, ctx.user, [retrieve: retriever()] ++ opts) ==
                 {:error, :wrong_document}
      end

      # A struct that names this document is checked against the database.
      forged = %{failed | inventory_uuid: other.uuid}

      assert InventoryAI.discard_run(forged, ctx.user, inventory_uuid: other.uuid) ==
               {:error, :wrong_document}

      assert InventoryAI.retry_run(forged, ctx.user,
               inventory_uuid: other.uuid,
               retrieve: retriever()
             ) == {:error, :wrong_document}

      refute_received {:ai_request, _}
      assert InventoryAI.get_run(ctx.doc.uuid, failed.uuid).status == "error"
      assert InventoryAI.list_runs(other.uuid) == []
    end

    test "a retry asks again with the photos the run has in the database", ctx do
      Stub.fail(401)
      {failed, _pid} = start!(ctx)
      failed = await(failed)

      Stub.answer(answer([object()]))
      tampered = %{failed | photo_file_uuids: [Ecto.UUID.generate()], place_label: "Elsewhere"}

      {:ok, retried, _pid} =
        InventoryAI.retry_run(tampered, ctx.user,
          inventory_uuid: ctx.doc.uuid,
          retrieve: retriever()
        )

      retried = await(retried)
      assert retried.photo_file_uuids == failed.photo_file_uuids
      assert retried.place_label == failed.place_label
    end

    test "a retry checks again that the photos are files of the document, none in the trash",
         ctx do
      Stub.fail(401)
      {failed, _pid} = start!(ctx)
      failed = await(failed)
      assert_received {:ai_request, _}
      [photo | _] = ctx.photos

      for change <- [[status: "trashed"], [status: "active", folder_uuid: nil]] do
        {1, _} = Repo.update_all(from(f in StorageFile, where: f.uuid == ^photo), set: change)

        assert InventoryAI.retry_run(failed, ctx.user,
                 inventory_uuid: ctx.doc.uuid,
                 retrieve: retriever()
               ) == {:error, :invalid_photos}
      end

      refute_received {:ai_request, _}
      assert InventoryAI.get_run(ctx.doc.uuid, failed.uuid).status == "error"
    end

    test "a photo in the trash is no photo of the document for a new run either", ctx do
      [photo | _] = ctx.photos

      {1, _} =
        Repo.update_all(from(f in StorageFile, where: f.uuid == ^photo), set: [status: "trashed"])

      assert InventoryAI.start_run(ctx.doc, attrs(ctx), ctx.user, retrieve: retriever()) ==
               {:error, :invalid_photos}
    end

    test "a discarded or applied run cannot be discarded again", ctx do
      Stub.answer(answer([object()]))
      {run, _pid} = start!(ctx)
      run = await(run)

      assert {:ok, %{status: "discarded"}} =
               InventoryAI.discard_run(run, ctx.user, inventory_uuid: ctx.doc.uuid)

      assert InventoryAI.discard_run(run, ctx.user, inventory_uuid: ctx.doc.uuid) ==
               {:error, :not_open}
    end
  end
end
