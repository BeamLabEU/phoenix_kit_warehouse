defmodule PhoenixKitWarehouse.InventoryAI do
  @moduledoc """
  The photo inventory: a person uploads the photos of one place in a draft
  inventory, the AI proposes the catalogue items it sees and how many, and
  the person applies what they tick. Nothing is written to the document
  without that.

  A run (`PhoenixKitWarehouse.InventoryAIRun`) is one batch of photos of one
  place and one call to the AI:

    * `start_run/4` checks what can be checked at once (the AI module on, an
      endpoint chosen, the photos, the size of the catalogue), records the
      run as `running` under the document's row lock - one running run per
      document - and asks the AI in a task of
      `PhoenixKitWarehouse.TaskSupervisor`
      (`PhoenixKitWarehouse.InventoryAI.Runner`). The task writes the result
      itself, so a closed page loses nothing, and broadcasts on `topic/1`.
    * `discard_run/2` closes a run (the task is not killed: the provider
      bills the call anyway); an answer that arrives later is kept in
      `late_result` and changes no status.
    * `retry_run/3` starts the photos of a failed run again and closes the
      failed one, so two live proposals never stand on the same photos.
    * `interrupt_run/1` - the page that started a run saw its task go down
      before a result; `expire_stale_runs/1` - a run `running` for more than
      ten minutes (the page closed, the node restarted) is closed as
      interrupted, when the document's runs are listed and before a new run.
    * `apply_run/5` writes the ticked rows into the document's lines
      (`PhoenixKitWarehouse.InventoryAI.Apply`).

  An error of a run is kept as the text the person who started it reads, in
  their language (`error_message/1`).
  """

  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.PubSubHelper
  alias PhoenixKitWarehouse.DraftTrash
  alias PhoenixKitWarehouse.InventoryAI.Apply
  alias PhoenixKitWarehouse.InventoryAI.CatalogueList
  alias PhoenixKitWarehouse.InventoryAI.Guard
  alias PhoenixKitWarehouse.InventoryAI.Runner
  alias PhoenixKitWarehouse.InventoryAI.Settings
  alias PhoenixKitWarehouse.InventoryAIRun
  alias PhoenixKitWarehouse.InventoryDocument

  @stale_after_seconds 600
  @open_statuses ~w(running proposed error)

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # --- the guard's seams, as the context names them ---------------------------------

  @doc "The endpoint chosen in the settings, as the list the AI task declaration asks for."
  @spec endpoint_uuids() :: [String.t()]
  defdelegate endpoint_uuids, to: Guard

  @doc "The AI tasks this module declares (empty while the ai it was built against has none)."
  @spec ai_tasks() :: [struct()]
  defdelegate ai_tasks, to: Guard

  # --- PubSub -------------------------------------------------------------------------

  @doc """
  The topic a document's runs are broadcast on. The message is
  `{:inventory_ai_run, %{run_uuid: uuid, status: status, late: boolean}}`.
  """
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(inventory_uuid), do: "warehouse:inventory_ai:#{inventory_uuid}"

  @doc "Subscribes the calling process to a document's runs."
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(inventory_uuid), do: PubSubHelper.subscribe(topic(inventory_uuid))

  @doc false
  def broadcast(%InventoryAIRun{} = run, late? \\ false) do
    PubSubHelper.broadcast(
      topic(run.inventory_uuid),
      {:inventory_ai_run, %{run_uuid: run.uuid, status: run.status, late: late?}}
    )
  rescue
    exception ->
      Logger.warning("[inventory ai] broadcast failed: #{inspect(exception.__struct__)}")
      :ok
  end

  # --- reading ------------------------------------------------------------------------

  @doc "A run by uuid, or `nil`."
  @spec get_run(Ecto.UUID.t()) :: InventoryAIRun.t() | nil
  def get_run(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(InventoryAIRun, uuid)
      :error -> nil
    end
  end

  @doc """
  The runs of a document, the newest first. A run left `running` for more
  than ten minutes is closed as interrupted first (`expire_stale_runs/1`).
  """
  @spec list_runs(Ecto.UUID.t()) :: [InventoryAIRun.t()]
  def list_runs(inventory_uuid) do
    expire_stale_runs(inventory_uuid)

    from(r in InventoryAIRun,
      where: r.inventory_uuid == ^inventory_uuid,
      order_by: [desc: r.inserted_at, desc: r.uuid]
    )
    |> repo().all()
  end

  # --- starting -----------------------------------------------------------------------

  @doc """
  Starts a run on the draft `doc` for `actor` (a user, or a map with
  `:uuid`).

  `attrs` (atom or string keys): `place_label` (optional, at most 200
  characters), `photo_file_uuids` (the Storage files, in their order),
  `catalogue_uuids` (optional; none is every catalogue).

  `{:ok, run, task_pid}` - the caller may monitor the task and call
  `interrupt_run/1` when it goes down. Errors: `:ai_disabled`,
  `:not_configured` (no endpoint chosen), `:no_photos`,
  `{:too_many_photos, count, max}`, `:place_too_long`,
  `{:too_many_items, count, max}`, `:not_draft`, `:deleted`,
  `:already_running`.

  Options: `:locale` (the language of the answer's texts and of the run's
  error; the caller's Gettext locale by default).
  """
  @spec start_run(InventoryDocument.t(), map(), term(), keyword()) ::
          {:ok, InventoryAIRun.t(), pid()} | {:error, term()}
  def start_run(%InventoryDocument{} = doc, attrs, actor, opts \\ []) do
    place = attrs |> attr(:place_label) |> normalize_place()
    photos = attrs |> attr(:photo_file_uuids) |> List.wrap()
    catalogue_uuids = attrs |> attr(:catalogue_uuids) |> List.wrap()

    with :ok <- check_ai(),
         {:ok, endpoint_uuid} <- endpoint(),
         :ok <- check_photos(photos),
         :ok <- check_place(place),
         :ok <- check_catalogue(catalogue_uuids),
         {:ok, run} <-
           insert_run(doc.uuid, %{
             place_label: place,
             photo_file_uuids: photos,
             endpoint_uuid: endpoint_uuid,
             created_by_uuid: actor_uuid(actor),
             result: scope(catalogue_uuids, opts)
           }) do
      launch(run, opts)
    end
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp normalize_place(label) when is_binary(label) do
    case String.trim(label) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_place(_label), do: nil

  defp check_ai do
    if PhoenixKitAI.enabled?(), do: :ok, else: {:error, :ai_disabled}
  end

  defp endpoint do
    case Settings.endpoint_uuid() do
      nil -> {:error, :not_configured}
      uuid -> {:ok, uuid}
    end
  end

  defp check_photos([]), do: {:error, :no_photos}

  defp check_photos(photos) do
    max = Settings.max_photos()

    cond do
      length(photos) > max -> {:error, {:too_many_photos, length(photos), max}}
      Enum.all?(photos, &match?({:ok, _}, Ecto.UUID.cast(&1))) -> :ok
      true -> {:error, :no_photos}
    end
  end

  defp check_place(nil), do: :ok

  defp check_place(place) do
    if String.length(place) <= InventoryAIRun.column_widths().place_label,
      do: :ok,
      else: {:error, :place_too_long}
  end

  defp check_catalogue(catalogue_uuids) do
    max = Settings.max_items()

    case CatalogueList.count(catalogue_uuids: catalogue_uuids) do
      count when count > max -> {:error, {:too_many_items, count, max}}
      _count -> :ok
    end
  end

  # What the task needs to ask again the same way (a retry): kept in the
  # run's result, where the answer is added later.
  defp scope(catalogue_uuids, opts) do
    %{"catalogue_uuids" => catalogue_uuids, "locale" => locale(opts)}
  end

  defp locale(opts),
    do: Keyword.get_lazy(opts, :locale, fn -> Gettext.get_locale(PhoenixKitWarehouse.Gettext) end)

  # Under the document's row lock: a live draft, stale runs closed, the
  # caller's own step (a retry closes the run it replaces), no other run
  # running - the partial unique index stands behind that check.
  defp insert_run(inventory_uuid, attrs, before_insert \\ fn _repo -> :ok end) do
    InventoryDocument
    |> DraftTrash.lock_status_step(inventory_uuid, "draft", :not_draft)
    |> Ecto.Multi.run(:stale, fn _repo, _ -> {:ok, expire_stale(inventory_uuid)} end)
    |> Ecto.Multi.run(:before_insert, fn repo, _ ->
      with :ok <- before_insert.(repo), do: {:ok, :done}
    end)
    |> Ecto.Multi.run(:none_running, fn _repo, _ -> none_running(inventory_uuid) end)
    |> Ecto.Multi.insert(:run, fn %{lock_status: doc} ->
      %InventoryAIRun{}
      |> Ecto.Changeset.change(
        Map.merge(attrs, %{
          inventory_uuid: inventory_uuid,
          location_uuid: doc.location_uuid,
          status: "running"
        })
      )
      |> Ecto.Changeset.unique_constraint(:inventory_uuid,
        name: :phoenix_kit_warehouse_inventory_ai_runs_running_index
      )
    end)
    |> repo().transaction()
    |> case do
      {:ok, %{run: run, stale: stale}} ->
        Enum.each(stale, &broadcast/1)
        {:ok, run}

      {:error, :run, %Ecto.Changeset{}, _changes} ->
        {:error, :already_running}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp none_running(inventory_uuid) do
    running? =
      repo().exists?(
        from(r in InventoryAIRun,
          where: r.inventory_uuid == ^inventory_uuid and r.status == "running"
        )
      )

    if running?, do: {:error, :already_running}, else: {:ok, :none}
  end

  defp launch(run, opts) do
    context = Runner.context(run, opts)

    case Task.Supervisor.start_child(PhoenixKitWarehouse.TaskSupervisor, fn ->
           Runner.run(context)
         end) do
      {:ok, pid} ->
        {:ok, run, pid}

      {:error, reason} ->
        Logger.warning("[inventory ai] the run #{run.uuid} could not start: #{inspect(reason)}")
        close_running(run.uuid, error_message(:interrupted))
        {:error, :not_started}
    end
  end

  # --- closing ------------------------------------------------------------------------

  @doc """
  Closes an open run (`running`, `proposed` or `error`) as `discarded`.
  `{:error, :not_open}` for one that is applied or discarded already.
  """
  @spec discard_run(InventoryAIRun.t(), term()) :: {:ok, InventoryAIRun.t()} | {:error, :not_open}
  def discard_run(%InventoryAIRun{uuid: uuid}, actor) do
    case close(uuid, @open_statuses, discarded(actor, "discarded", nil)) do
      {:ok, run} ->
        broadcast(run)
        {:ok, run}

      :none ->
        {:error, :not_open}
    end
  end

  @doc """
  Starts the photos of a failed run again and closes the failed run as
  `discarded` (replaced by the retry) in the same transaction. Only a run in
  `error` can be retried. `{:ok, new_run, task_pid}`, or the errors of
  `start_run/4` and `:not_error`.
  """
  @spec retry_run(InventoryAIRun.t(), term(), keyword()) ::
          {:ok, InventoryAIRun.t(), pid()} | {:error, term()}
  def retry_run(%InventoryAIRun{} = run, actor, opts \\ []) do
    scope = run.result || %{}
    catalogue_uuids = scope["catalogue_uuids"] || []
    opts = Keyword.put_new(opts, :locale, scope["locale"] || locale(opts))
    new_uuid = UUIDv7.generate()

    with :ok <- check_ai(),
         {:ok, endpoint_uuid} <- endpoint(),
         :ok <- check_catalogue(catalogue_uuids),
         {:ok, new_run} <-
           insert_run(
             run.inventory_uuid,
             %{
               uuid: new_uuid,
               place_label: run.place_label,
               photo_file_uuids: run.photo_file_uuids,
               endpoint_uuid: endpoint_uuid,
               created_by_uuid: actor_uuid(actor),
               result: scope(catalogue_uuids, opts)
             },
             fn _repo -> close_failed(run.uuid, discarded(actor, "retried", new_uuid)) end
           ) do
      broadcast(%{run | status: "discarded"})
      launch(new_run, opts)
    end
  end

  defp close_failed(uuid, decisions) do
    case close(uuid, ["error"], decisions) do
      {:ok, _run} -> :ok
      :none -> {:error, :not_error}
    end
  end

  defp discarded(actor, reason, replaced_by) do
    %{
      "discarded" =>
        %{"by_uuid" => actor_uuid(actor), "at" => DateTime.to_iso8601(now()), "reason" => reason}
        |> then(&if(replaced_by, do: Map.put(&1, "replaced_by_run_uuid", replaced_by), else: &1))
    }
  end

  defp close(uuid, statuses, decisions) do
    {count, runs} =
      from(r in InventoryAIRun, where: r.uuid == ^uuid and r.status in ^statuses, select: r)
      |> repo().update_all(set: [status: "discarded", decisions: decisions, updated_at: now()])

    if count == 1, do: {:ok, hd(runs)}, else: :none
  end

  @doc """
  The page that started a run saw its task go down without a result: the
  run, still `running`, is closed as `error` (interrupted). `:ok` when it
  was, `:noop` when the run had already finished.
  """
  @spec interrupt_run(InventoryAIRun.t() | Ecto.UUID.t()) :: :ok | :noop
  def interrupt_run(%InventoryAIRun{uuid: uuid}), do: interrupt_run(uuid)

  def interrupt_run(uuid) when is_binary(uuid) do
    case close_running(uuid, error_message(:interrupted)) do
      {:ok, run} ->
        broadcast(run)
        :ok

      :none ->
        :noop
    end
  end

  defp close_running(uuid, error) do
    {count, runs} =
      from(r in InventoryAIRun, where: r.uuid == ^uuid and r.status == "running", select: r)
      |> repo().update_all(set: [status: "error", error: error, updated_at: now()])

    if count == 1, do: {:ok, hd(runs)}, else: :none
  end

  @doc """
  Closes as interrupted the runs of a document left `running` for more than
  ten minutes - no answer takes that long, so their task is gone. Returns
  how many were closed.
  """
  @spec expire_stale_runs(Ecto.UUID.t()) :: non_neg_integer()
  def expire_stale_runs(inventory_uuid) do
    runs = expire_stale(inventory_uuid)
    Enum.each(runs, &broadcast/1)
    length(runs)
  end

  defp expire_stale(inventory_uuid) do
    cutoff = DateTime.add(now(), -@stale_after_seconds, :second)

    {_count, runs} =
      from(r in InventoryAIRun,
        where:
          r.inventory_uuid == ^inventory_uuid and r.status == "running" and
            r.inserted_at < ^cutoff,
        select: r
      )
      |> repo().update_all(
        set: [status: "error", error: error_message(:interrupted), updated_at: now()]
      )

    runs
  end

  @doc "How long a run may stay `running` before it is taken as interrupted, in seconds."
  @spec stale_after_seconds() :: pos_integer()
  def stale_after_seconds, do: @stale_after_seconds

  # --- applying -----------------------------------------------------------------------

  @doc """
  Applies the ticked rows of a proposed run to the document's lines, in one
  transaction - see `PhoenixKitWarehouse.InventoryAI.Apply.apply_run/6`
  (`inventory_uuid:` - the document the caller's tab holds).
  """
  @spec apply_run(InventoryAIRun.t(), String.t() | nil, [map()], [map()], term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate apply_run(run, base_fingerprint, socket_lines, rows, actor, opts \\ []), to: Apply

  # --- texts --------------------------------------------------------------------------

  @doc """
  The text a person reads for a failure of the photo inventory - a run's
  error, or a refusal of `start_run/4`, `retry_run/3`, `apply_run/5`. An
  error of the AI call itself is ai's own text (`PhoenixKitAI.Errors.message/1`).
  """
  @spec error_message(term()) :: String.t()
  def error_message(:ai_disabled), do: dgettext("default", "The AI module is switched off.")

  def error_message(:not_configured),
    do:
      dgettext("default", "No AI endpoint is chosen for the inventory in the warehouse settings.")

  def error_message(:no_photos), do: dgettext("default", "None of the photos could be read.")

  def error_message({:too_many_photos, count, max}),
    do:
      dgettext("default", "Too many photos for one batch: %{count}, at most %{max}.",
        count: count,
        max: max
      )

  def error_message(:place_too_long),
    do: dgettext("default", "The place is too long: at most 200 characters.")

  def error_message({:too_many_items, count, max}),
    do:
      dgettext(
        "default",
        "The chosen catalogues hold %{count} items, more than %{max}: choose fewer catalogues.",
        count: count,
        max: max
      )

  def error_message(:empty_catalogue),
    do: dgettext("default", "The chosen catalogues have no items.")

  def error_message({:too_large, bytes, max}),
    do:
      dgettext(
        "default",
        "The photos are too large together (%{size} MB, at most %{max} MB): send fewer.",
        size: div(bytes, 1_000_000),
        max: div(max, 1_000_000)
      )

  def error_message(:truncated),
    do: dgettext("default", "The answer did not fit: send fewer photos in one batch.")

  def error_message(:not_an_object),
    do: dgettext("default", "The AI did not answer in the expected form.")

  def error_message({:off_purpose, reason}),
    do: dgettext("default", "The photos do not look like a warehouse: %{reason}", reason: reason)

  def error_message(:interrupted), do: dgettext("default", "Reading the photos was interrupted.")

  def error_message(:already_running),
    do: dgettext("default", "Another batch of this document is being read.")

  def error_message(:not_draft), do: dgettext("default", "The document is not a draft.")
  def error_message(:deleted), do: dgettext("default", "The document is in the trash.")

  def error_message(:stale),
    do: dgettext("default", "The document was changed in another tab: reload the page.")

  def error_message(:not_proposed),
    do: dgettext("default", "This batch has been applied or discarded already.")

  def error_message(:not_open), do: dgettext("default", "This batch is closed already.")
  def error_message(:not_error), do: dgettext("default", "Only a failed batch can be retried.")

  def error_message(:location_changed),
    do: dgettext("default", "The warehouse of the document changed after this batch was read.")

  def error_message(:nothing_to_apply), do: dgettext("default", "No row is ticked.")

  def error_message(:wrong_document),
    do: dgettext("default", "This batch belongs to another document.")

  def error_message(:invalid_lines),
    do: dgettext("default", "The lines of the document cannot be read.")

  def error_message({:invalid_rows, _errors}),
    do: dgettext("default", "Some ticked rows are not complete: check the marked fields.")

  def error_message(:not_started),
    do: dgettext("default", "Reading the photos could not be started.")

  def error_message(reason), do: PhoenixKitAI.Errors.message(reason)

  # --- helpers ------------------------------------------------------------------------

  @doc false
  def actor_uuid(%{uuid: uuid}), do: uuid
  def actor_uuid(uuid) when is_binary(uuid), do: uuid
  def actor_uuid(_actor), do: nil

  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
