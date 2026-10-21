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
    * `discard_run/3` closes a run (the task is not killed: the provider
      bills the call anyway); an answer that arrives later is kept in
      `late_result` and changes no status.
    * `retry_run/3` starts the photos of a failed run again and closes the
      failed one, so two live proposals never stand on the same photos.
    * `interrupt_run/1` - the page that started a run saw its task go down
      before a result; `expire_stale_runs/1` - a run `running` for more than
      ten minutes (the page closed, the node restarted) is closed as
      interrupted, when the document's runs are listed and before a new run.
    * `apply_run/6` writes the ticked rows into the document's lines
      (`PhoenixKitWarehouse.InventoryAI.Apply`).
    * `show_late_result/3` - a person shows the answer that came to a failed
      run after it failed; `close_open_runs/3` - the warehouse of the
      document changed, or it was posted: its running and proposed runs are
      closed.
    * `store_photo/3` - an uploaded photo goes into the document's Storage
      folder, where `start_run/4` takes its photos from.

  A run is read and changed only through its document: `get_run/2` takes
  the document, and `discard_run/3`, `retry_run/3` and `apply_run/6` take it
  as `inventory_uuid:` (the document the caller's page holds) - a run of
  another document, or a call without one, is `{:error, :wrong_document}`.

  An error of a run is kept as the text the person who started it reads, in
  their language (`error_message/1`).
  """

  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FolderLink
  alias PhoenixKit.PubSubHelper
  alias PhoenixKitWarehouse.DraftTrash
  alias PhoenixKitWarehouse.InventoryAI.Apply
  alias PhoenixKitWarehouse.InventoryAI.CatalogueList
  alias PhoenixKitWarehouse.InventoryAI.Guard
  alias PhoenixKitWarehouse.InventoryAI.Photos
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

  # --- photos -------------------------------------------------------------------------

  @doc """
  Stores an uploaded photo in the document's Storage folder, as a file of
  `actor` - see `PhoenixKitWarehouse.InventoryAI.Photos.store/3`. The photos
  of a run are files of that folder (`start_run/4`).
  """
  @spec store_photo(InventoryDocument.t(), map(), term()) ::
          {:ok, StorageFile.t()} | {:error, term()}
  def store_photo(%InventoryDocument{} = doc, upload, actor),
    do: Photos.store(doc, upload, actor_uuid(actor))

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

  @doc "A run of the document `inventory_uuid` by its uuid, or `nil`."
  @spec get_run(Ecto.UUID.t(), Ecto.UUID.t()) :: InventoryAIRun.t() | nil
  def get_run(inventory_uuid, uuid) do
    with {:ok, inventory_uuid} <- Ecto.UUID.cast(inventory_uuid),
         {:ok, uuid} <- Ecto.UUID.cast(uuid) do
      repo().get_by(InventoryAIRun, uuid: uuid, inventory_uuid: inventory_uuid)
    else
      :error -> nil
    end
  end

  # The document the caller holds, as `inventory_uuid:`, must be the run's.
  defp own_run(%InventoryAIRun{} = run, opts) do
    with {:ok, inventory_uuid} <- Keyword.fetch(opts, :inventory_uuid),
         %InventoryAIRun{} = stored <- get_run(inventory_uuid, run.uuid) do
      {:ok, stored}
    else
      _ -> {:error, :wrong_document}
    end
  end

  @doc """
  The runs of a document, the newest first. A run left `running` for more
  than ten minutes is closed as interrupted first (`expire_stale_runs/1`).

  The list is for showing the runs: it leaves out the large columns
  `result`, `catalogue_map` and `late_result` (left at their defaults) and
  says in `late_answer?` whether there is a late answer. `get_run/2` reads
  a whole run.
  """
  @spec list_runs(Ecto.UUID.t()) :: [InventoryAIRun.t()]
  def list_runs(inventory_uuid) do
    expire_stale_runs(inventory_uuid)

    from(r in InventoryAIRun,
      where: r.inventory_uuid == ^inventory_uuid,
      order_by: [desc: r.inserted_at, desc: r.uuid],
      select: struct(r, ^listed_fields()),
      select_merge: %{late_answer?: not is_nil(r.late_result)}
    )
    |> repo().all()
  end

  defp listed_fields,
    do: InventoryAIRun.__schema__(:fields) -- [:result, :catalogue_map, :late_result]

  # --- starting -----------------------------------------------------------------------

  @doc """
  Starts a run on the draft `doc` for `actor` (a user, or a map with
  `:uuid`).

  `attrs` (atom or string keys): `place_label` (optional, at most 200
  characters), `photo_file_uuids` (the Storage files, in their order; a
  file given twice is sent once), `catalogue_uuids` (optional; none is
  every catalogue).

  Every photo must be a file of the document's Storage folder (its home
  folder, or linked into it) - the photos go to a third-party model, and
  only those uploaded to this document may. That is checked under the
  document's row lock.

  `{:ok, run, task_pid}` - the caller may monitor the task and call
  `interrupt_run/1` when it goes down. Errors: `:ai_disabled`,
  `:not_configured` (no endpoint chosen), `:no_photos`, `:invalid_photos`
  (not a uuid, not a file of the document's folder, or in the trash),
  `{:too_many_photos, count, max}`, `:place_too_long`,
  `:invalid_catalogues`, `{:too_many_items, count, max}`, `:not_draft`,
  `:deleted`, `:already_running`.

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
         {:ok, photos} <- check_photos(photos),
         :ok <- check_place(place),
         {:ok, catalogue_uuids} <- cast_catalogues(catalogue_uuids),
         :ok <- check_catalogue(catalogue_uuids),
         {:ok, run} <-
           insert_run(
             doc.uuid,
             %{
               place_label: place,
               photo_file_uuids: photos,
               endpoint_uuid: endpoint_uuid,
               created_by_uuid: actor_uuid(actor),
               result: scope(catalogue_uuids, opts)
             },
             &document_photos(&1, &2, photos)
           ) do
      launch(run, opts)
    end
  end

  @doc """
  The checks of `start_run/4` that need neither the photos nor the
  document: the AI on, an endpoint chosen, no more photos than the
  maximum, the place, the catalogues and how many items they hold. A caller
  that stores the photos before it starts the run asks this first, so a
  run that would be refused leaves the photos alone; `start_run/4` checks
  it all again.

  `attrs` (atom or string keys): `place_label` and `catalogue_uuids` as for
  `start_run/4`, `photo_count`. The errors are `start_run/4`'s.
  """
  @spec check_start(map()) :: :ok | {:error, term()}
  def check_start(attrs) do
    place = attrs |> attr(:place_label) |> normalize_place()

    with :ok <- check_ai(),
         {:ok, _endpoint_uuid} <- endpoint(),
         :ok <- check_photo_count(attr(attrs, :photo_count) || 0),
         :ok <- check_place(place),
         {:ok, catalogue_uuids} <-
           attrs |> attr(:catalogue_uuids) |> List.wrap() |> cast_catalogues() do
      check_catalogue(catalogue_uuids)
    end
  end

  defp check_photo_count(count) do
    max = Settings.max_photos()
    if count > max, do: {:error, {:too_many_photos, count, max}}, else: :ok
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
    with {:ok, photos} <- cast_uuids(photos, :invalid_photos),
         photos = Enum.uniq(photos),
         :ok <- check_photo_count(length(photos)),
         do: {:ok, photos}
  end

  defp cast_uuids(values, error) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, cast} ->
      case Ecto.UUID.cast(value) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | cast]}}
        :error -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, cast} -> {:ok, Enum.reverse(cast)}
      error -> error
    end
  end

  # The photos are files of the document's folder, not in the trash: their
  # home folder, or a link into it.
  defp document_photos(_repo, %InventoryDocument{storage_folder_uuid: nil}, _photos),
    do: {:error, :invalid_photos}

  defp document_photos(repo, %InventoryDocument{storage_folder_uuid: folder}, photos) do
    found =
      from(f in StorageFile,
        left_join: l in FolderLink,
        on: l.file_uuid == f.uuid and l.folder_uuid == ^folder,
        where:
          f.uuid in ^photos and f.status != "trashed" and
            (f.folder_uuid == ^folder or not is_nil(l.uuid)),
        select: count(f.uuid, :distinct)
      )
      |> repo.one()

    if found == length(photos), do: :ok, else: {:error, :invalid_photos}
  end

  defp check_place(nil), do: :ok

  defp check_place(place) do
    if String.length(place) <= InventoryAIRun.column_widths().place_label,
      do: :ok,
      else: {:error, :place_too_long}
  end

  defp cast_catalogues(catalogue_uuids) do
    with {:ok, uuids} <- cast_uuids(catalogue_uuids, :invalid_catalogues),
         do: {:ok, Enum.uniq(uuids)}
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
  # caller's own step (a start checks its photos against the document, a
  # retry closes the run it replaces), no other run running - the partial
  # unique index stands behind that check.
  defp insert_run(inventory_uuid, attrs, before_insert) do
    InventoryDocument
    |> DraftTrash.lock_status_step(inventory_uuid, "draft", :not_draft)
    |> Ecto.Multi.run(:stale, fn _repo, _ -> {:ok, expire_stale(inventory_uuid)} end)
    |> Ecto.Multi.run(:before_insert, fn repo, %{lock_status: doc} ->
      with :ok <- before_insert.(repo, doc), do: {:ok, :done}
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
  `{:error, :not_open}` for one that is applied or discarded already,
  `{:error, :wrong_document}` unless `opts` names the run's document as
  `inventory_uuid:`.
  """
  @spec discard_run(InventoryAIRun.t(), term(), keyword()) ::
          {:ok, InventoryAIRun.t()} | {:error, :not_open | :wrong_document}
  def discard_run(%InventoryAIRun{} = run, actor, opts) do
    with {:ok, run} <- own_run(run, opts) do
      case close(run, @open_statuses, discarded(actor, "discarded", nil)) do
        {:ok, run} ->
          broadcast(run)
          {:ok, run}

        :none ->
          {:error, :not_open}
      end
    end
  end

  @doc """
  Starts the photos of a failed run again and closes the failed run as
  `discarded` (replaced by the retry) in the same transaction. Only a run in
  `error` can be retried; the photos, the place and the catalogues are the
  run's as the database has them, and the photos are checked again as for
  `start_run/4` (files of the document's folder, none in the trash).
  `{:ok, new_run, task_pid}`, or the errors
  of `start_run/4`, `:not_error` and `:wrong_document` (`opts` must name the
  run's document as `inventory_uuid:`).
  """
  @spec retry_run(InventoryAIRun.t(), term(), keyword()) ::
          {:ok, InventoryAIRun.t(), pid()} | {:error, term()}
  def retry_run(%InventoryAIRun{} = run, actor, opts) do
    with {:ok, run} <- own_run(run, opts) do
      retry_stored(run, actor, opts)
    end
  end

  defp retry_stored(run, actor, opts) do
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
             fn repo, doc ->
               with :ok <- document_photos(repo, doc, run.photo_file_uuids),
                    do: close_failed(run, discarded(actor, "retried", new_uuid))
             end
           ) do
      broadcast(%{run | status: "discarded"})
      launch(new_run, opts)
    end
  end

  defp close_failed(run, decisions) do
    case close(run, ["error"], decisions) do
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

  defp close(run, statuses, decisions) do
    {count, runs} =
      from(r in InventoryAIRun,
        where:
          r.uuid == ^run.uuid and r.inventory_uuid == ^run.inventory_uuid and
            r.status in ^statuses,
        select: r
      )
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

  @doc """
  Shows the answer that came to a failed run after it failed: the run
  becomes the proposal of that answer (`error -> proposed`). Only by a
  person's action, only for a run in `error` that holds a `late_result` (a
  run replaced by a retry is `discarded`, so its answer is never shown),
  only while the document is a live draft. `{:error, :no_late_result}`
  otherwise; `:not_draft`, `:deleted`, `:wrong_document` (`opts` must name
  the run's document as `inventory_uuid:`).
  """
  @spec show_late_result(InventoryAIRun.t(), term(), keyword()) ::
          {:ok, InventoryAIRun.t()} | {:error, term()}
  def show_late_result(%InventoryAIRun{} = run, _actor, opts) do
    with {:ok, run} <- own_run(run, opts) do
      InventoryDocument
      |> DraftTrash.lock_status_step(run.inventory_uuid, "draft", :not_draft)
      |> Ecto.Multi.run(:shown, fn repo, _ -> show_late(repo, run) end)
      |> repo().transaction()
      |> case do
        {:ok, %{shown: shown}} ->
          broadcast(shown)
          {:ok, shown}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp show_late(repo, run) do
    case repo.get(InventoryAIRun, run.uuid) do
      %InventoryAIRun{status: "error", late_result: %{"result" => %{} = result} = late} ->
        from(r in InventoryAIRun, where: r.uuid == ^run.uuid and r.status == "error", select: r)
        |> repo.update_all(
          set: [
            status: "proposed",
            result: result,
            catalogue_map: late["catalogue_map"] || %{},
            photo_file_uuids: late["photo_file_uuids"] || run.photo_file_uuids,
            model: late["model"],
            prompt_uuid: late["prompt_uuid"],
            ai_request_uuid: late["ai_request_uuid"],
            error: nil,
            updated_at: now()
          ]
        )
        |> case do
          {1, [shown]} -> {:ok, shown}
          # The run changed since it was read (a discard in another tab).
          {0, _none} -> {:error, :no_late_result}
        end

      _ ->
        {:error, :no_late_result}
    end
  end

  @doc """
  Closes the open runs of a document (`running` and `proposed`) as
  `discarded`, with `reason` - the warehouse of the document changed
  (`"location_changed"`: its lines were seeded again), or the document was
  posted (`"posted"`). The task of a running run is not killed; its answer
  goes to `late_result`. Returns how many were closed.
  """
  @spec close_open_runs(Ecto.UUID.t(), term(), String.t()) :: non_neg_integer()
  def close_open_runs(inventory_uuid, actor, reason) do
    {_count, runs} =
      from(r in InventoryAIRun,
        where: r.inventory_uuid == ^inventory_uuid and r.status in ["running", "proposed"],
        select: r
      )
      |> repo().update_all(
        set: [status: "discarded", decisions: discarded(actor, reason, nil), updated_at: now()]
      )

    Enum.each(runs, &broadcast/1)
    length(runs)
  end

  # --- applying -----------------------------------------------------------------------

  @doc """
  Applies the ticked rows of a proposed run to the document's lines, in one
  transaction - see `PhoenixKitWarehouse.InventoryAI.Apply.apply_run/6`
  (`inventory_uuid:` - the document the caller's tab holds, required).
  """
  @spec apply_run(InventoryAIRun.t(), String.t() | nil, [map()], [map()], term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate apply_run(run, base_fingerprint, socket_lines, rows, actor, opts), to: Apply

  # --- texts --------------------------------------------------------------------------

  @doc """
  The text a person reads for a failure of the photo inventory - a run's
  error, or a refusal of `start_run/4`, `retry_run/3`, `apply_run/6`. An
  error of the AI call itself is ai's own text (`PhoenixKitAI.Errors.message/1`).
  """
  @spec error_message(term()) :: String.t()
  def error_message(:ai_disabled), do: dgettext("default", "The AI module is switched off.")

  def error_message(:not_configured),
    do:
      dgettext("default", "No AI endpoint is chosen for the inventory in the warehouse settings.")

  def error_message(:no_photos), do: dgettext("default", "None of the photos could be read.")

  def error_message(:invalid_photos),
    do: dgettext("default", "Some of the photos are not files of this document.")

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

  def error_message(:invalid_catalogues),
    do: dgettext("default", "Some of the chosen catalogues cannot be found.")

  def error_message(:empty_catalogue),
    do: dgettext("default", "The chosen catalogues have no items.")

  def error_message({:too_large, bytes, max}),
    do:
      dgettext(
        "default",
        "The photos are too large together (%{size} MB, at most %{max} MB): send fewer.",
        size: div(bytes + 999_999, 1_000_000),
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

  def error_message(:no_late_result),
    do: dgettext("default", "This batch has no late answer to show.")

  def error_message(:wrong_document),
    do: dgettext("default", "This batch belongs to another document.")

  def error_message(:invalid_lines),
    do: dgettext("default", "The lines of the document cannot be read.")

  def error_message({:invalid_rows, _errors}),
    do: dgettext("default", "Some ticked rows are not complete: check the marked fields.")

  def error_message(:not_stored),
    do: dgettext("default", "A photo could not be stored: upload it again.")

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
