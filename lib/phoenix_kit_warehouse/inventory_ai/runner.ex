defmodule PhoenixKitWarehouse.InventoryAI.Runner do
  @moduledoc """
  The task of a photo inventory run (spec §6.1, §10.3): prepares the photos,
  builds the catalogue, asks the AI once, checks the answer, and writes the
  result into the run itself - the page that started it may be gone.

  Everything runs under `try` with `rescue` and `catch :exit`: a crash, or
  the exit of a pool or a `GenServer.call`, closes the run as `error` at
  once instead of leaving it `running`. The log of such a failure names its
  kind and where it happened, never the values it carried: the arguments
  of a failed call inside the AI module include the endpoint (and its key)
  and the photos.

  The result is written with one of two updates:

    * the usual one, only while the run is still `running` - status
      `proposed` (or `error`), the result, the model;
    * when the run was closed meanwhile (discarded, or taken as
      interrupted), an answer goes to `late_result` and the status stays.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKitWarehouse.ActivityLog
  alias PhoenixKitWarehouse.InventoryAI
  alias PhoenixKitWarehouse.InventoryAI.CatalogueList
  alias PhoenixKitWarehouse.InventoryAI.Guard
  alias PhoenixKitWarehouse.InventoryAI.Photos
  alias PhoenixKitWarehouse.InventoryAI.Prompt
  alias PhoenixKitWarehouse.InventoryAI.Proposal
  alias PhoenixKitWarehouse.InventoryAI.Response
  alias PhoenixKitWarehouse.InventoryAIRun
  alias PhoenixKitWarehouse.InventoryDocument

  @source "PhoenixKitWarehouse.InventoryAI"
  @max_tokens 24_000

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc false
  # What the task needs, taken in the caller's process. `:retrieve` (how an
  # original photo is fetched) is the photos' seam for tests.
  def context(%InventoryAIRun{} = run, opts) do
    scope = run.result || %{}

    %{
      run_uuid: run.uuid,
      inventory_uuid: run.inventory_uuid,
      location_uuid: run.location_uuid,
      place_label: run.place_label,
      photo_file_uuids: run.photo_file_uuids,
      endpoint_uuid: run.endpoint_uuid,
      user_uuid: run.created_by_uuid,
      catalogue_uuids: scope["catalogue_uuids"] || [],
      locale: scope["locale"] || Keyword.get(opts, :locale) || "en",
      scope: scope,
      photo_opts: Keyword.take(opts, [:retrieve])
    }
  end

  @doc "The body of the task."
  @spec run(map()) :: :ok
  def run(context) do
    Gettext.put_locale(context.locale)

    outcome =
      try do
        execute(context)
      rescue
        exception ->
          Logger.error(
            "[inventory ai] run #{context.run_uuid} crashed: #{failure_kind(exception)} at #{where(__STACKTRACE__)}"
          )

          {:error, InventoryAI.error_message(:interrupted), %{}}
      catch
        :exit, reason ->
          Logger.error("[inventory ai] run #{context.run_uuid} exited: #{failure_kind(reason)}")
          {:error, InventoryAI.error_message(:interrupted), %{}}
      end

    finish(context, outcome)
  end

  # --- the steps ------------------------------------------------------------------------

  defp execute(context) do
    with {:ok, photos} <- photos(context),
         {:ok, catalogue} <- catalogue(context),
         {:ok, prompt, text} <- prompt(),
         {:ok, response} <- ask(context, photos, catalogue, text) do
      bump_usage(prompt)

      found = %{
        prompt_uuid: prompt.uuid,
        model: response.model,
        ai_request_uuid: Guard.request_uuid(response)
      }

      checked(
        context,
        Response.check(response.json, %{
          photo_count: length(photos.images),
          numbers: catalogue.numbers
        }),
        photos,
        catalogue,
        found
      )
    end
  end

  defp photos(context) do
    case Photos.prepare(context.photo_file_uuids, context.photo_opts) do
      {:ok, photos} -> {:ok, photos}
      {:error, reason} -> {:error, InventoryAI.error_message(reason), %{}}
    end
  end

  defp catalogue(context) do
    case CatalogueList.build(context.location_uuid, catalogue_uuids: context.catalogue_uuids) do
      {:ok, %{count: 0}} -> {:error, InventoryAI.error_message(:empty_catalogue), %{}}
      {:ok, catalogue} -> {:ok, catalogue}
      {:error, reason} -> {:error, InventoryAI.error_message(reason), %{}}
    end
  end

  defp prompt do
    with {:ok, prompt} <- Prompt.ensure(),
         {:ok, text} <- PhoenixKitAI.render_prompt(prompt, %{}) do
      {:ok, prompt, text}
    else
      {:error, reason} -> {:error, InventoryAI.error_message(reason), %{}}
    end
  end

  defp ask(context, photos, catalogue, rules) do
    request = rules <> "\n\nLANGUAGE: #{context.locale}\n\nCATALOGUE\n" <> catalogue.text

    opts =
      [
        prompt: request,
        schema: Response.schema(),
        schema_name: Response.schema_name(),
        max_tokens: @max_tokens,
        user_uuid: context.user_uuid,
        source: @source,
        idempotency_key: "inventory:#{context.inventory_uuid}:#{context.run_uuid}"
      ] ++
        Guard.call_options(%{
          "inventory_uuid" => context.inventory_uuid,
          "run_uuid" => context.run_uuid
        })

    case PhoenixKitAI.describe_image(context.endpoint_uuid, photos.images, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        text =
          if Response.truncated?(reason),
            do: InventoryAI.error_message(:truncated),
            else: InventoryAI.error_message(reason)

        {:error, text,
         %{catalogue_map: catalogue.catalogue_map, photo_file_uuids: photos.file_uuids}}
    end
  end

  # The prompt's usage count is a side note: it never fails the run.
  defp bump_usage(prompt) do
    PhoenixKitAI.increment_prompt_usage(prompt)
  rescue
    exception ->
      Logger.warning("[inventory ai] usage count failed: #{inspect(exception.__struct__)}")
  end

  defp checked(context, {:off_purpose, reason}, photos, catalogue, found) do
    report_off_purpose(context, reason, found.ai_request_uuid)

    {:error, InventoryAI.error_message({:off_purpose, reason}),
     Map.merge(found, %{
       catalogue_map: catalogue.catalogue_map,
       photo_file_uuids: photos.file_uuids
     })}
  end

  defp checked(_context, {:error, reason}, photos, catalogue, found) do
    {:error, InventoryAI.error_message(reason),
     Map.merge(found, %{
       catalogue_map: catalogue.catalogue_map,
       photo_file_uuids: photos.file_uuids
     })}
  end

  defp checked(context, {:ok, checked}, photos, catalogue, found) do
    result =
      Map.merge(context.scope, %{
        "rows" => Proposal.build(checked.objects, catalogue.items),
        "nothing_found" => checked.nothing_found,
        "overlap" => checked.overlap,
        "warnings" => checked.warnings,
        "skipped_photos" => photos.skipped,
        "catalogue_count" => catalogue.count
      })

    {:proposed, result,
     Map.merge(found, %{
       catalogue_map: catalogue.catalogue_map,
       photo_file_uuids: photos.file_uuids
     })}
  end

  defp report_off_purpose(context, reason, request_uuid) do
    Guard.report_off_purpose(Guard.task_key(), context.user_uuid, reason, request_uuid)
  end

  # --- writing the outcome -------------------------------------------------------------

  defp finish(context, {:proposed, result, fields}) do
    set =
      Keyword.merge(fields_set(fields),
        status: "proposed",
        result: result,
        error: nil,
        updated_at: InventoryAI.now()
      )

    case update_running(context.run_uuid, set) do
      {:ok, run} ->
        log_proposed(run, result)
        InventoryAI.broadcast(run)

      :none ->
        keep_late(context.run_uuid, result, fields)
    end

    :ok
  rescue
    exception -> failed_write(context, exception)
  catch
    :exit, reason -> failed_write(context, reason)
  end

  defp finish(context, {:error, text, fields}) do
    set =
      Keyword.merge(fields_set(fields),
        status: "error",
        error: text,
        updated_at: InventoryAI.now()
      )

    case update_running(context.run_uuid, set) do
      {:ok, run} -> InventoryAI.broadcast(run)
      :none -> :ok
    end

    :ok
  rescue
    exception -> failed_write(context, exception)
  catch
    :exit, reason -> failed_write(context, reason)
  end

  defp fields_set(fields) do
    fields
    |> Map.take([:prompt_uuid, :model, :ai_request_uuid, :catalogue_map, :photo_file_uuids])
    |> Map.to_list()
  end

  defp update_running(uuid, set) do
    {count, runs} =
      from(r in InventoryAIRun, where: r.uuid == ^uuid and r.status == "running", select: r)
      |> repo().update_all(set: set)

    if count == 1, do: {:ok, hd(runs)}, else: :none
  end

  # The run was closed while the AI was answering: the answer is kept, the
  # status is not touched.
  defp keep_late(uuid, result, fields) do
    late = %{
      "result" => result,
      "catalogue_map" => fields[:catalogue_map],
      "photo_file_uuids" => fields[:photo_file_uuids],
      "model" => fields[:model],
      "prompt_uuid" => fields[:prompt_uuid],
      "ai_request_uuid" => fields[:ai_request_uuid],
      "received_at" => DateTime.to_iso8601(InventoryAI.now())
    }

    {count, runs} =
      from(r in InventoryAIRun,
        where: r.uuid == ^uuid and r.status in ["error", "discarded"],
        select: r
      )
      |> repo().update_all(set: [late_result: late, updated_at: InventoryAI.now()])

    if count == 1, do: InventoryAI.broadcast(hd(runs), true)
  end

  defp log_proposed(run, result) do
    case repo().get(InventoryDocument, run.inventory_uuid) do
      %InventoryDocument{} = doc ->
        ActivityLog.log_inventory_ai_proposed(
          doc,
          %{
            run_uuid: run.uuid,
            photo_count: length(run.photo_file_uuids),
            model: run.model,
            rows: length(result["rows"])
          },
          actor_uuid: run.created_by_uuid
        )

      nil ->
        :ok
    end
  end

  # Writing the outcome failed (the database is gone, say): one more try to
  # close the run, so that it is not left running; the stale check of the
  # page catches it otherwise.
  defp failed_write(context, reason) do
    Logger.error(
      "[inventory ai] run #{context.run_uuid}: the outcome could not be written: #{failure_kind(reason)}"
    )

    InventoryAI.interrupt_run(context.run_uuid)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # --- what a log line may say about a failure -----------------------------------------

  # The kind of a failure without its values: an exception's module, an
  # exit's shape (`{:timeout, ...}`), never the terms inside.
  defp failure_kind(%{__exception__: true} = exception), do: inspect(exception.__struct__)
  defp failure_kind(reason) when is_atom(reason), do: inspect(reason)

  defp failure_kind({%{__exception__: true} = exception, _stacktrace}),
    do: failure_kind(exception)

  defp failure_kind(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: "{#{inspect(elem(reason, 0))}, ...}"

  defp failure_kind(_reason), do: "an exit of another shape"

  # The frames of a stacktrace as module, function and arity - a frame that
  # carries the call's arguments is cut down to their count.
  defp where(stacktrace) do
    stacktrace
    |> Enum.take(3)
    |> Enum.map_join(" < ", fn
      {module, fun, args, location} when is_list(args) ->
        Exception.format_stacktrace_entry({module, fun, length(args), location})

      entry ->
        Exception.format_stacktrace_entry(entry)
    end)
  end
end
