defmodule PhoenixKitWarehouse.InventoryAI.GuardTest do
  # The "phoenix_kit_ai task guard" seams (spec §2.1, §13.3): every one works
  # on the ai module as it is today (no `Tasks`, `Guard`, `TaskSpec`) and
  # reaches for the guard when a later ai ships it. The later ai is played
  # by modules defined in the test under the names it will have.
  use PhoenixKitWarehouse.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKitWarehouse.InventoryAI.Guard
  alias PhoenixKitWarehouse.InventoryAI.Settings, as: AISettings

  @task "warehouse.inventory_photo"
  @source Path.expand("../../../lib/phoenix_kit_warehouse/inventory_ai/guard.ex", __DIR__)

  setup do
    Settings.update_setting(AISettings.endpoint_key(), "")
    :ok
  end

  # Defines the module `source` under the module name `name`, for the length
  # of the test.
  defp define_module(name, source) do
    [{^name, _}] = Code.compile_string(source)

    on_exit(fn ->
      :code.purge(name)
      :code.delete(name)
    end)
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

  describe "endpoint_options/0 without the guard" do
    test "lists every enabled endpoint" do
      on = endpoint!(%{name: "Vision on"})
      off = endpoint!(%{name: "Vision off", enabled: false})

      options = Guard.endpoint_options()

      assert %{uuid: on_uuid, name: "Vision on", model: "google/gemini-flash"} =
               Enum.find(options, &(&1.uuid == on.uuid))

      assert on_uuid == on.uuid
      refute Enum.any?(options, &(&1.uuid == off.uuid))
    end

    test "lists more than one page of endpoints" do
      for i <- 1..25, do: endpoint!(%{name: "Many #{i}"})

      assert length(Guard.endpoint_options()) >= 25
    end
  end

  describe "endpoint_options/0 with the guard" do
    setup do
      refute Code.ensure_loaded?(PhoenixKitAI.Tasks),
             "ai ships PhoenixKitAI.Tasks now: this test plays it and must be rewritten"

      :ok
    end

    test "asks the guard for the task's endpoints; its fit marks are not kept (ai refuses a call)" do
      fit = endpoint!(%{name: "Fits"})
      unfit = endpoint!(%{name: "Does not fit"})
      Process.put(:endpoints, [{fit, :fit}, {unfit, {:unfit, [:vision]}}])

      define_module(PhoenixKitAI.Tasks, """
      defmodule PhoenixKitAI.Tasks do
        def endpoint_options(task), do: send(self(), {:asked, task}) && Process.get(:endpoints)
      end
      """)

      options = Guard.endpoint_options()

      assert_received {:asked, @task}

      assert Enum.map(options, & &1.uuid) == [fit.uuid, unfit.uuid]
      assert Enum.all?(options, &(Map.keys(&1) |> Enum.sort() == [:model, :name, :uuid]))
    end

    test "takes an endpoint the guard lists without a mark" do
      bare = endpoint!(%{name: "Bare"})
      Process.put(:endpoints, [bare])

      define_module(PhoenixKitAI.Tasks, """
      defmodule PhoenixKitAI.Tasks do
        def endpoint_options(_task), do: Process.get(:endpoints)
      end
      """)

      assert Enum.map(Guard.endpoint_options(), & &1.uuid) == [bare.uuid]
    end

    test "a guard that raises gives every enabled endpoint and a warning" do
      on = endpoint!(%{name: "Still offered"})

      define_module(PhoenixKitAI.Tasks, """
      defmodule PhoenixKitAI.Tasks do
        def endpoint_options(_task), do: raise("registry is down")
      end
      """)

      log =
        capture_log(fn ->
          assert on.uuid in Enum.map(Guard.endpoint_options(), & &1.uuid)
        end)

      assert log =~ "Tasks.endpoint_options/1 raised"
      assert log =~ "offering every enabled endpoint"
    end

    test "a guard that exits gives every enabled endpoint and a warning" do
      on = endpoint!(%{name: "Offered after an exit"})

      define_module(PhoenixKitAI.Tasks, """
      defmodule PhoenixKitAI.Tasks do
        def endpoint_options(_task), do: exit(:noproc)
      end
      """)

      log =
        capture_log(fn ->
          assert on.uuid in Enum.map(Guard.endpoint_options(), & &1.uuid)
        end)

      assert log =~ "Tasks.endpoint_options/1 exited"
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
    test "is unavailable while ai has no guard" do
      refute Code.ensure_loaded?(PhoenixKitAI.Guard)

      assert Guard.report_off_purpose(@task, "user-1", "a selfie", nil) == :unavailable
    end

    test "reaches the guard when ai has one" do
      define_module(PhoenixKitAI.Guard, """
      defmodule PhoenixKitAI.Guard do
        def report_off_purpose(task, user, reason, ref) do
          send(Process.get(:test_pid), {:reported, task, user, reason, ref})
          :ok
        end
      end
      """)

      Process.put(:test_pid, self())

      assert Guard.report_off_purpose(@task, "user-1", "a selfie", "req-1") == :ok
      assert_received {:reported, @task, "user-1", "a selfie", "req-1"}
    end

    test "a guard that raises does not break the count" do
      define_module(PhoenixKitAI.Guard, """
      defmodule PhoenixKitAI.Guard do
        def report_off_purpose(_task, _user, _reason, _ref), do: raise("boom")
      end
      """)

      assert {:error, _} = Guard.report_off_purpose(@task, "user-1", "a selfie", nil)
    end

    test "a guard that exits does not break the count" do
      define_module(PhoenixKitAI.Guard, """
      defmodule PhoenixKitAI.Guard do
        def report_off_purpose(_task, _user, _reason, _ref), do: exit(:noproc)
      end
      """)

      assert {:error, _} = Guard.report_off_purpose(@task, "user-1", "a selfie", nil)
    end
  end

  describe "ai_tasks/0" do
    test "is empty while ai has no TaskSpec, and the module compiled all the same" do
      refute Code.ensure_loaded?(PhoenixKitAI.TaskSpec)

      assert Guard.ai_tasks() == []
      assert PhoenixKitWarehouse.ai_tasks() == []
    end

    test "declares the task when ai has the TaskSpec" do
      define_module(PhoenixKitAI.TaskSpec, """
      defmodule PhoenixKitAI.TaskSpec do
        defstruct [
          :key, :label, :gettext_backend, :purpose, :needs, :self_flag,
          :auto_block_threshold, :endpoints, private: false
        ]
      end
      """)

      # The module compiled afresh now that the struct is there.
      source = File.read!(@source)

      define_module(
        PhoenixKitWarehouse.InventoryAI.GuardWithSpec,
        String.replace(
          source,
          "defmodule PhoenixKitWarehouse.InventoryAI.Guard do",
          "defmodule PhoenixKitWarehouse.InventoryAI.GuardWithSpec do"
        )
      )

      # Defined at run time just above: named by Module.concat/1, so that a
      # plain call does not warn at compile time.
      guard_with_spec = Module.concat(["PhoenixKitWarehouse", "InventoryAI", "GuardWithSpec"])

      assert [spec] = guard_with_spec.ai_tasks()
      assert spec.__struct__ == PhoenixKitAI.TaskSpec
      assert spec.key == @task
      assert spec.needs == [:vision, :json_schema]
      assert spec.self_flag == true
      assert spec.auto_block_threshold == 0
      assert spec.gettext_backend == PhoenixKitWarehouse.Gettext
      assert spec.label == "Inventory count from photos"
      assert is_binary(spec.purpose) and spec.purpose != ""
      assert spec.endpoints == {PhoenixKitWarehouse.InventoryAI, :endpoint_uuids, []}
      refute spec.purpose =~ ~r/\bandi\b/i
    end
  end
end
