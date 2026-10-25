defmodule PhoenixKitWarehouse.InventoryAI.Guard do
  @moduledoc """
  The seams of the photo inventory with the AI task guard of `phoenix_kit_ai`.

  The guard (a registry of AI tasks, a fit check of the model for the task,
  limits, the off-purpose signal) ships in `phoenix_kit_ai` 0.26; the
  `~> 0.25` requirement still admits a 0.25 without it. Every function here
  works on both and reaches for the guard only when it is there - by the
  module being loaded and the function exported, so that no direct call can
  break the build against an ai without it:

    * `call_options/1` - `task:` and `attribution:` for `describe_image/3`;
      an option the call does not know is ignored by it;
    * `request_uuid/1` - the uuid of the journal row, when the answer carries
      one;
    * `endpoint_options/0` - the endpoints the settings page offers: the
      guard's own list for the task, or every enabled endpoint;
    * `report_off_purpose/4` - the model's "these photos are not about a
      warehouse" signal;
    * `ai_tasks/0` - the declaration of the task, present only when the ai at
      the compile time has `PhoenixKitAI.TaskSpec`, otherwise `[]`.

  Every seam is marked "phoenix_kit_ai task guard".
  """

  use Gettext, backend: PhoenixKitWarehouse.Gettext

  require Logger

  alias PhoenixKitWarehouse.InventoryAI.Settings

  @task_key "warehouse.inventory_photo"

  @endpoints_page_size 1000

  @doc "The key the task is declared and called under."
  @spec task_key() :: String.t()
  def task_key, do: @task_key

  @doc false
  # The label of the task, as the msgid the guard's pages translate with
  # `PhoenixKitWarehouse.Gettext`. Marked for extraction here, outside the
  # compile-time condition of `ai_tasks/0`, so that the catalogues keep it
  # whatever ai this is built against.
  @spec label() :: String.t()
  def label, do: dgettext_noop("default", "Inventory count from photos")

  @doc false
  # The purpose of the task, a msgid like `label/0`: the guard's pages show it
  # translated with `PhoenixKitWarehouse.Gettext`, the guard's prompts keep
  # this English text.
  @spec purpose() :: String.t()
  def purpose,
    do:
      dgettext_noop(
        "default",
        "Counts stock on the photos of a warehouse inventory: names the catalogue items that are visible and how many of each. Photos of shelves, boxes and stacks; nothing else is asked."
      )

  # --- phoenix_kit_ai task guard: the options of the call ---------------------------

  @doc """
  The options that name the task of a `PhoenixKitAI.describe_image/3` call
  (phoenix_kit_ai task guard): `task:` and `attribution:`.
  """
  @spec call_options(map()) :: keyword()
  def call_options(attribution) when is_map(attribution),
    do: [task: @task_key, attribution: attribution]

  # --- phoenix_kit_ai task guard: the journal row of the call -----------------------

  @doc """
  The uuid of the journal row the call wrote (phoenix_kit_ai task guard): the
  answer's `:request_uuid` when it has one, otherwise `nil` - today's ai does
  not return it.
  """
  @spec request_uuid(term()) :: String.t() | nil
  def request_uuid(%{request_uuid: uuid}) when is_binary(uuid) and uuid != "", do: uuid
  def request_uuid(_response), do: nil

  # --- phoenix_kit_ai task guard: the endpoints to choose from ----------------------

  @doc """
  The endpoints the settings page offers (phoenix_kit_ai task guard): what
  `PhoenixKitAI.Tasks.endpoint_options/1` says for the task when the ai has
  it, otherwise every enabled endpoint. Each is
  `%{uuid, name, model}`. The guard's own fit mark is not kept: a model that
  does not fit is refused by ai at the call (`{:model_unfit, _}`), and
  nothing is sent or written.
  """
  @spec endpoint_options() :: [map()]
  def endpoint_options do
    case guard_endpoint_options() do
      {:ok, options} -> options
      :unavailable -> enabled_endpoint_options()
    end
  end

  @doc """
  The endpoint chosen in the settings, as the list the task declaration asks
  for (`endpoints:` of the `TaskSpec`).
  """
  @spec endpoint_uuids() :: [String.t()]
  def endpoint_uuids do
    case Settings.endpoint_uuid() do
      nil -> []
      uuid -> [uuid]
    end
  end

  defp guard_endpoint_options do
    with {:ok, tasks} <- optional_module(["PhoenixKitAI", "Tasks"], :endpoint_options, 1) do
      {:ok, @task_key |> tasks.endpoint_options() |> Enum.flat_map(&option/1)}
    end
  rescue
    exception -> unavailable("Tasks.endpoint_options/1 raised #{inspect(exception.__struct__)}")
  catch
    :exit, _reason -> unavailable("Tasks.endpoint_options/1 exited")
  end

  defp unavailable(message) do
    Logger.warning("[inventory ai] #{message}; offering every enabled endpoint")
    :unavailable
  end

  # ai 0.26 answers `%{endpoint: endpoint, fitness: fitness}` per endpoint.
  defp option(%{endpoint: %{uuid: _} = endpoint}), do: [to_option(endpoint)]
  defp option({%{uuid: _} = endpoint, _fit}), do: [to_option(endpoint)]
  defp option(%{uuid: _} = endpoint), do: [to_option(endpoint)]
  defp option(_other), do: []

  defp to_option(endpoint),
    do: %{uuid: endpoint.uuid, name: endpoint.name, model: endpoint.model}

  defp enabled_endpoint_options do
    {endpoints, _total} =
      PhoenixKitAI.list_endpoints(enabled: true, page_size: @endpoints_page_size)

    Enum.map(endpoints, &to_option/1)
  end

  # --- phoenix_kit_ai task guard: the off-purpose signal ----------------------------

  @doc """
  Tells the guard the photos were not about a warehouse (phoenix_kit_ai task
  guard): `PhoenixKitAI.Guard.report_off_purpose/4` when the ai has it.
  `:unavailable` without it; a signal that fails is `{:error, reason}` and is
  logged - it never stops the count.
  """
  @spec report_off_purpose(String.t(), String.t() | nil, String.t(), String.t() | nil) ::
          :ok | :unavailable | {:error, term()}
  def report_off_purpose(task, user_uuid, reason, request_uuid) do
    case optional_module(["PhoenixKitAI", "Guard"], :report_off_purpose, 4) do
      {:ok, guard} -> signal(guard, task, user_uuid, reason, request_uuid)
      :unavailable -> :unavailable
    end
  end

  defp signal(guard, task, user_uuid, reason, request_uuid) do
    case guard.report_off_purpose(task, user_uuid, reason, request_uuid) do
      {:error, failure} -> failed(failure)
      _ok -> :ok
    end
  rescue
    exception -> failed(exception.__struct__)
  catch
    :exit, reason -> failed({:exit, reason})
  end

  # Only what failed, never the reason text the model wrote.
  defp failed(reason) do
    Logger.warning("[inventory ai] the off-purpose signal failed: #{inspect(reason)}")
    {:error, reason}
  end

  # The module is named at run time, so that no direct call sits in the code
  # of a build against an ai without it.
  defp optional_module(parts, function, arity) do
    module = Module.concat(parts)

    if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
      do: {:ok, module},
      else: :unavailable
  end

  # --- phoenix_kit_ai task guard: the declaration of the task -----------------------

  if Code.ensure_loaded?(PhoenixKitAI.TaskSpec) do
    @doc """
    The task the guard knows this module's AI use by (phoenix_kit_ai task
    guard). `PhoenixKitWarehouse.ai_tasks/0` hands it to the guard's registry.
    `self_flag: true` with no automatic block (`auto_block_threshold: nil`):
    the module flags the off-purpose photos itself, a flag gives a signal, and
    only a person blocks. `typical_tokens` is one batch of the probes: the
    photos plus the whole catalogue in, the counted objects out. Built with
    `struct/2`, which leaves out a field the installed `TaskSpec` does not
    have yet: a literal would not compile against it.
    """
    @spec ai_tasks() :: [struct()]
    def ai_tasks do
      [
        struct(PhoenixKitAI.TaskSpec,
          key: @task_key,
          label: label(),
          gettext_backend: PhoenixKitWarehouse.Gettext,
          needs: [:vision, :json_schema],
          purpose: purpose(),
          self_flag: true,
          auto_block_threshold: nil,
          typical_tokens: {30_000, 4_000},
          endpoints: {PhoenixKitWarehouse.InventoryAI, :endpoint_uuids, []}
        )
      ]
    end
  else
    @doc """
    The AI tasks of the module. Empty: the `phoenix_kit_ai` this was built
    against has no `PhoenixKitAI.TaskSpec` (phoenix_kit_ai task guard).
    """
    @spec ai_tasks() :: []
    def ai_tasks, do: []
  end
end
