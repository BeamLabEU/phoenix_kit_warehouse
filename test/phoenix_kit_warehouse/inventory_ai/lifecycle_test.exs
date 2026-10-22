defmodule PhoenixKitWarehouse.InventoryAI.LifecycleTest do
  # What closes and reopens runs besides the run itself (spec §10.3, §11.5):
  # the late answer shown by hand, the open runs closed when the warehouse
  # changes or the document is posted.
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.InventoryAIFixtures

  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryAI
  alias PhoenixKitWarehouse.InventoryAIRun
  alias PhoenixKitWarehouse.Web.InventoryAIPanel

  setup do
    user = user!()
    location = Ecto.UUID.generate()
    catalogue = catalogue!("Fittings")
    hinge = item!(catalogue, %{name: "Hinge"})
    doc = draft!(location)

    %{user: user, location: location, catalogue: catalogue, hinge: hinge, doc: doc}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp run!(doc, status, attrs \\ %{}) do
    %InventoryAIRun{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          inventory_uuid: doc.uuid,
          location_uuid: doc.location_uuid,
          place_label: "A",
          photo_file_uuids: [Ecto.UUID.generate()],
          status: status
        },
        attrs
      )
    )
    |> repo().insert!()
  end

  defp late(ctx) do
    proposed = proposed_run!(ctx.doc, "A", [object(%{"loose_units" => 3})], [ctx.catalogue.uuid])
    repo().delete!(proposed)

    %{
      "result" => proposed.result,
      "catalogue_map" => proposed.catalogue_map,
      "photo_file_uuids" => [Ecto.UUID.generate()],
      "model" => "test/late-model",
      "prompt_uuid" => nil,
      "ai_request_uuid" => nil,
      "received_at" => "2026-10-21T10:00:00Z"
    }
  end

  defp status(run), do: repo().get!(InventoryAIRun, run.uuid).status

  describe "the late answer, shown by hand" do
    test "a failed run with a late answer becomes the proposal of that answer", ctx do
      late = late(ctx)
      run = run!(ctx.doc, "error", %{error: "interrupted", late_result: late})
      :ok = InventoryAI.subscribe(ctx.doc.uuid)

      assert {:ok, shown} =
               InventoryAI.show_late_result(run, ctx.user, inventory_uuid: ctx.doc.uuid)

      assert shown.status == "proposed"
      assert shown.error == nil
      assert shown.model == "test/late-model"
      assert shown.result["rows"] == late["result"]["rows"]
      assert shown.catalogue_map == late["catalogue_map"]
      assert shown.photo_file_uuids == late["photo_file_uuids"]

      uuid = run.uuid
      assert_receive {:inventory_ai_run, %{run_uuid: ^uuid, status: "proposed"}}
    end

    test "only a failed run, with a late answer, of a live draft, through its document", ctx do
      late = late(ctx)

      discarded = run!(ctx.doc, "discarded", %{late_result: late})

      assert InventoryAI.show_late_result(discarded, ctx.user, inventory_uuid: ctx.doc.uuid) ==
               {:error, :no_late_result}

      bare = run!(ctx.doc, "error")

      assert InventoryAI.show_late_result(bare, ctx.user, inventory_uuid: ctx.doc.uuid) ==
               {:error, :no_late_result}

      failed = run!(ctx.doc, "error", %{late_result: late})
      other = draft!(ctx.location)

      assert InventoryAI.show_late_result(failed, ctx.user, inventory_uuid: other.uuid) ==
               {:error, :wrong_document}

      {:ok, _} = Inventories.soft_delete_document(ctx.doc, ctx.user.uuid)

      assert InventoryAI.show_late_result(failed, ctx.user, inventory_uuid: ctx.doc.uuid) ==
               {:error, :deleted}

      assert status(failed) == "error"
    end

    test "a run changed between the read and the write has no late answer to show", ctx do
      run = run!(ctx.doc, "error", %{error: "interrupted", late_result: late(ctx)})

      # The update of the run is skipped, as when a discard commits between
      # the read of the run and its update: no row is written.
      repo().query!("""
      CREATE FUNCTION pkw_test_skip_run_update() RETURNS trigger AS $$
      BEGIN
        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql
      """)

      repo().query!("""
      CREATE TRIGGER pkw_test_skip_run_update BEFORE UPDATE ON phoenix_kit_warehouse_inventory_ai_runs
      FOR EACH ROW EXECUTE FUNCTION pkw_test_skip_run_update()
      """)

      assert InventoryAI.show_late_result(run, ctx.user, inventory_uuid: ctx.doc.uuid) ==
               {:error, :no_late_result}

      assert status(run) == "error"
    end
  end

  describe "closing the open runs" do
    test "warehouse cleanup preserves runs started for the new warehouse after the switch", ctx do
      old = run!(ctx.doc, "proposed")
      {:ok, moved} = Inventories.update_draft(ctx.doc, %{location_uuid: Ecto.UUID.generate()})
      running = run!(moved, "running")
      proposed = run!(moved, "proposed")

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          doc: moved,
          current_user: ctx.user,
          ai: %{run: nil, review: nil, picking: nil, runs: [], users: %{}, retaken: MapSet.new()}
        }
      }

      InventoryAIPanel.close_open_runs(socket, "location_changed")

      assert status(old) == "discarded"
      assert status(running) == "running"
      assert status(proposed) == "proposed"
    end

    test "running and proposed runs are discarded; the others stay", ctx do
      running = run!(ctx.doc, "running")
      proposed = run!(ctx.doc, "proposed")
      failed = run!(ctx.doc, "error")
      applied = run!(ctx.doc, "applied")
      other_doc = draft!(ctx.location)
      elsewhere = run!(other_doc, "proposed")
      :ok = InventoryAI.subscribe(ctx.doc.uuid)

      assert InventoryAI.close_open_runs(ctx.doc.uuid, ctx.user, "location_changed") == 2

      assert status(running) == "discarded"
      assert status(proposed) == "discarded"
      assert status(failed) == "error"
      assert status(applied) == "applied"
      assert status(elsewhere) == "proposed"

      closed = repo().get!(InventoryAIRun, proposed.uuid)
      assert closed.decisions["discarded"]["reason"] == "location_changed"
      assert closed.decisions["discarded"]["by_uuid"] == ctx.user.uuid

      uuid = proposed.uuid
      assert_receive {:inventory_ai_run, %{run_uuid: ^uuid, status: "discarded"}}
    end
  end
end
