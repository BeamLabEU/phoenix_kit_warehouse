defmodule PhoenixKitWarehouse.InventoryAI.GuardTest do
  # The "phoenix_kit_ai task guard" seams (spec §2.1, §13.3), run against the
  # real guard of phoenix_kit_ai 0.26 (`Tasks`, `Guard`, `TaskSpec`). The
  # fallbacks for a 0.25 without it are a `Code.ensure_loaded?` away and can
  # no longer be played here: redefining a module ai ships would replace it
  # for the rest of the run.
  use PhoenixKitWarehouse.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKitWarehouse.InventoryAI.Guard
  alias PhoenixKitWarehouse.InventoryAI.Settings, as: AISettings

  @task "warehouse.inventory_photo"

  setup do
    Settings.update_setting(AISettings.endpoint_key(), "")
    :ok
  end

  defp endpoint!(attrs) do
    base = %{
      name: "Guard test #{System.unique_integer([:positive])}",
      provider: "openrouter",
      model: "google/gemini-flash",
      api_key: "test-key"
    }

    {:ok, endpoint} = PhoenixKitAI.create_endpoint(Map.merge(base, attrs))
    endpoint
  end

  test "the task key" do
    assert Guard.task_key() == @task
  end

  test "the label and the purpose are msgids translated in every locale of the catalogue" do
    for locale <- ["et", "ru", "uk"], text <- [Guard.label(), Guard.purpose()] do
      translated =
        Gettext.with_locale(PhoenixKitWarehouse.Gettext, locale, fn ->
          Gettext.dgettext(PhoenixKitWarehouse.Gettext, "default", text)
        end)

      assert translated != text, "#{inspect(text)} has no #{locale} translation"
    end
  end

  describe "call_options/1" do
    test "names the task and the attribution of the call" do
      attribution = %{"inventory_uuid" => "i-1", "run_uuid" => "r-1"}

      assert Guard.call_options(attribution) == [task: @task, attribution: attribution]
    end
  end

  describe "request_uuid/1" do
    test "reads the uuid of the journal row when the answer carries one" do
      assert Guard.request_uuid(%{text: "t", json: %{}, request_uuid: "req-1"}) == "req-1"
    end

    test "is nil for the answer of today's ai, which has none" do
      assert Guard.request_uuid(%{text: "t", json: %{}, model: "m"}) == nil
      assert Guard.request_uuid(%{request_uuid: nil}) == nil
      assert Guard.request_uuid(%{request_uuid: ""}) == nil
      assert Guard.request_uuid(nil) == nil
    end
  end

  describe "endpoint_options/0" do
    test "lists every enabled endpoint, from the guard's own list for the task" do
      on = endpoint!(%{name: "Vision on"})
      off = endpoint!(%{name: "Vision off", enabled: false})

      options = Guard.endpoint_options()

      assert %{uuid: on_uuid, name: "Vision on", model: "google/gemini-flash"} =
               Enum.find(options, &(&1.uuid == on.uuid))

      assert on_uuid == on.uuid
      refute Enum.any?(options, &(&1.uuid == off.uuid))
    end

    test "keeps only uuid, name and model: the guard's fit mark is not kept (ai refuses a call)" do
      endpoint!(%{name: "Marked"})

      # ai 0.26 answers %{endpoint: _, fitness: _} per endpoint.
      assert [%{endpoint: _, fitness: _} | _] =
               PhoenixKitAI.Tasks.endpoint_options(Guard.task_key())

      options = Guard.endpoint_options()

      assert options != []
      assert Enum.all?(options, &(Map.keys(&1) |> Enum.sort() == [:model, :name, :uuid]))
    end

    test "lists more than one page of endpoints" do
      for i <- 1..25, do: endpoint!(%{name: "Many #{i}"})

      assert length(Guard.endpoint_options()) >= 25
    end
  end

  describe "endpoint_uuids/0" do
    test "is the chosen endpoint, as the task declaration wants it" do
      assert Guard.endpoint_uuids() == []

      uuid = Ecto.UUID.generate()
      :ok = AISettings.set_endpoint_uuid(uuid)
      assert Guard.endpoint_uuids() == [uuid]
    end
  end

  describe "report_off_purpose/4" do
    test "reaches the guard; a refusal is an error and never breaks the count" do
      # The task is not in the guard's registry in this suite, so the real
      # guard refuses it; the seam returns the refusal and logs it.
      log =
        capture_log(fn ->
          assert {:error, :unknown_task} =
                   Guard.report_off_purpose(@task, nil, "a selfie", Ecto.UUID.generate())
        end)

      assert log =~ "the off-purpose signal failed"
      refute log =~ "a selfie"
    end
  end

  describe "ai_tasks/0" do
    test "declares the task, now that ai has the TaskSpec" do
      assert [spec] = Guard.ai_tasks()
      assert PhoenixKitWarehouse.ai_tasks() == [spec]

      assert spec.__struct__ == PhoenixKitAI.TaskSpec
      assert spec.key == @task
      assert spec.needs == [:vision, :json_schema]
      assert spec.self_flag == true
      assert spec.auto_block_threshold == nil
      assert spec.gettext_backend == PhoenixKitWarehouse.Gettext
      assert spec.label == "Inventory count from photos"
      assert is_binary(spec.purpose) and spec.purpose != ""
      assert spec.endpoints == {PhoenixKitWarehouse.InventoryAI, :endpoint_uuids, []}
    end
  end
end
