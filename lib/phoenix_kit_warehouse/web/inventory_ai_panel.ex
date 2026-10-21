defmodule PhoenixKitWarehouse.Web.InventoryAIPanel do
  @moduledoc """
  The photo inventory on the Items tab of a draft inventory (spec §5, §11):
  the panel that uploads the photos of one place and starts a run, the list
  of the document's runs, and the proposal a person reviews and applies.

  `PhoenixKitWarehouse.Web.InventoryFormLive` only delegates: `mount/1`
  after `MediaBrowser.setup_uploads/1` (the panel's own upload comes after
  the Files tab's `:media_files`), `load/1` after the document is read,
  `handle_event/4` for every `inventory_ai_*` event, `handle_info/2` for the
  runs' broadcasts, the task monitors and the item picker; and the function
  components here render it. The panel's state is one assign, `:ai`.

  Every event is checked on the server (spec §11.6): the document is a live
  draft (read again from the database for anything that writes), the person
  may edit it, a run named by an event is one of this document's, a row is
  one of the run's proposal, a chosen item exists and is active. Writing to
  the lines goes only through `PhoenixKitWarehouse.InventoryAI.apply_run/6`,
  with the tab's base fingerprint; the tab's buffer and base are then the
  written lines and their fingerprint (`on_written`, the form's own).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import Phoenix.LiveView,
    only: [allow_upload: 3, cancel_upload: 3, connected?: 1, consume_uploaded_entries: 3]

  import PhoenixKitWeb.Components.Core.DecimalInput, only: [decimal_input: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Role
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Web.Components.ItemPicker
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryAI
  alias PhoenixKitWarehouse.InventoryAI.CatalogueList
  alias PhoenixKitWarehouse.InventoryAI.Lines
  alias PhoenixKitWarehouse.InventoryAI.Review
  alias PhoenixKitWarehouse.InventoryAI.Settings
  alias PhoenixKitWarehouse.InventoryAIRun
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Web.Components.WarehouseBrowser
  alias PhoenixKitWarehouse.Web.UserNames

  @upload :inventory_ai_photos
  @max_file_size 20_000_000
  @picker_prefix "inventory-ai-picker-"

  # --- the form's lifecycle ------------------------------------------------------------

  @doc """
  The panel's state and its upload. Call after `MediaBrowser.setup_uploads/1`:
  that one does nothing once `uploads` exists, so it must come first.
  """
  @spec mount(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def mount(socket) do
    socket
    |> assign(:ai, initial_state(socket))
    |> allow_upload(@upload,
      accept: ~w(image/* .heic .heif),
      max_entries: Settings.max_photos(),
      max_file_size: @max_file_size,
      auto_upload: true
    )
  end

  defp initial_state(socket) do
    %{
      enabled?: false,
      can_edit?: can_edit?(socket.assigns[:phoenix_kit_current_scope]),
      open?: false,
      place: "",
      catalogue_uuids: [],
      catalogues: [],
      catalogue_count: nil,
      max_items: nil,
      runs: [],
      stored_photos: [],
      users: %{},
      retaken: MapSet.new(),
      run: nil,
      review: nil,
      picking: nil,
      error: nil,
      notice: nil,
      started: MapSet.new(),
      monitors: %{},
      subscribed: nil,
      doc_uuid: nil
    }
  end

  # The person may edit a draft: the warehouse permission, or an Owner or
  # Admin (spec §13.2). Any single permission opens the admin area, so that
  # alone is not enough.
  defp can_edit?(nil), do: false

  defp can_edit?(scope) do
    Scope.has_module_access?(scope, PhoenixKitWarehouse.module_key()) or Scope.owner?(scope) or
      Scope.has_role?(scope, Role.system_roles().admin)
  end

  @doc """
  After the form read its document: whether the photo inventory is on for
  it, the document's runs, the subscription to them. A proposal of another
  document, or one no longer proposed, is closed.
  """
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(%{assigns: %{doc: %InventoryDocument{} = doc}} = socket) do
    ai = socket.assigns.ai
    ai = if ai.doc_uuid == doc.uuid, do: ai, else: %{initial_state(socket) | doc_uuid: doc.uuid}

    ai = %{
      ai
      | enabled?: PhoenixKitAI.enabled?() and is_binary(Settings.endpoint_uuid()),
        subscribed: subscribe(socket, ai, doc)
    }

    socket |> assign(:ai, ai) |> reload_runs()
  end

  def load(socket), do: socket

  # Once per document, when connected; a page that moves to another
  # document hears the new one's runs only (the old ones are ignored by uuid).
  defp subscribe(socket, ai, doc) do
    cond do
      not connected?(socket) -> nil
      ai.subscribed == doc.uuid -> doc.uuid
      InventoryAI.subscribe(doc.uuid) == :ok -> doc.uuid
      true -> nil
    end
  end

  defp reload_runs(%{assigns: %{doc: %InventoryDocument{status: "draft"} = doc}} = socket) do
    runs = InventoryAI.list_runs(doc.uuid)
    ai = socket.assigns.ai

    ai =
      case ai.run && Enum.find(runs, &(&1.uuid == ai.run.uuid)) do
        %InventoryAIRun{status: "proposed"} -> ai
        nil when is_nil(ai.run) -> ai
        _closed -> %{ai | run: nil, review: nil, picking: nil}
      end

    assign(socket, :ai, %{
      ai
      | runs: runs,
        users: UserNames.resolve(runs, [:created_by_uuid, :applied_by_uuid]),
        retaken: retaken(runs)
    })
  end

  defp reload_runs(socket), do: socket

  # The failed runs with a late answer that newer runs of the document
  # followed (the list is the newest first): the place may have been
  # photographed again since.
  defp retaken(runs) do
    runs
    |> Enum.with_index()
    |> Enum.filter(fn {run, index} ->
      index > 0 and run.status == "error" and run.late_answer?
    end)
    |> MapSet.new(fn {run, _index} -> run.uuid end)
  end

  @doc """
  The warehouse of the document changed (its lines seeded again) or it was
  posted: its open runs are closed (spec §11.5), the proposal too.
  """
  @spec close_open_runs(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def close_open_runs(%{assigns: %{doc: %InventoryDocument{} = doc}} = socket, reason) do
    InventoryAI.close_open_runs(doc.uuid, socket.assigns.current_user, reason)
    socket |> update_ai(&%{&1 | run: nil, review: nil, picking: nil}) |> reload_runs()
  end

  def close_open_runs(socket, _reason), do: socket

  # --- events ----------------------------------------------------------------------------

  @doc """
  An `inventory_ai_*` event of the panel. `on_written` takes the socket and
  the document `apply_run/6` read back, and makes its lines and fingerprint
  the tab's buffer and base.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t(), function()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket, on_written) do
    socket = update_ai(socket, &%{&1 | error: nil, notice: nil})

    case permitted(socket) do
      :ok -> {:noreply, event(event, params, socket, on_written)}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  defp permitted(%{assigns: %{doc: %InventoryDocument{} = doc, ai: ai}}) do
    cond do
      not ai.can_edit? -> {:error, :not_permitted}
      doc.deleted_at -> {:error, :deleted}
      doc.status != "draft" -> {:error, :not_draft}
      true -> :ok
    end
  end

  defp permitted(_socket), do: {:error, :not_draft}

  # The document as the database has it, for anything that writes.
  defp live_draft(socket) do
    case Inventories.get_document(socket.assigns.doc.uuid) do
      {:ok, %InventoryDocument{deleted_at: %DateTime{}}} -> {:error, :deleted}
      {:ok, %InventoryDocument{status: "draft"} = doc} -> {:ok, doc}
      _ -> {:error, :not_draft}
    end
  end

  defp event("inventory_ai_toggle", _params, socket, _on_written) do
    if socket.assigns.ai.open? do
      update_ai(socket, &%{&1 | open?: false})
    else
      catalogues =
        Catalogue.list_catalogues()
        |> Enum.map(fn catalogue ->
          %{
            uuid: catalogue.uuid,
            name:
              catalogue
              |> WarehouseBrowser.localized_name(socket.assigns.locale)
              |> WarehouseBrowser.strip_prefix()
          }
        end)

      socket
      |> update_ai(&%{&1 | open?: true, catalogues: catalogues})
      |> count_catalogue()
    end
  end

  defp event("inventory_ai_change", params, socket, _on_written),
    do: put_form(socket, params)

  # A ref the upload no longer has (a second click on the cross) is ignored.
  defp event("inventory_ai_cancel_upload", %{"ref" => ref}, socket, _on_written)
       when is_binary(ref) do
    if Enum.any?(socket.assigns.uploads[@upload].entries, &(&1.ref == ref)),
      do: cancel_upload(socket, @upload, ref),
      else: socket
  end

  # The place and the catalogues come with the submit: Enter in the place
  # field drops the change still waiting for its debounce. The photos a
  # refused run already stored go with the new uploads, and a refusal after
  # the uploads were stored keeps them all for the next Propose.
  defp event("inventory_ai_run", params, socket, _on_written) do
    socket = put_form(socket, params)

    with :ok <- ready(socket),
         :ok <- check_start(socket),
         {:ok, doc} <- live_draft(socket) do
      {stored, store_result} = store_uploads(socket, doc)
      start(socket, doc, socket.assigns.ai.stored_photos ++ stored, store_result)
    else
      {:error, reason} -> fail(socket, reason)
    end
  end

  # The photos stored for a refused run are not sent with the next one; they
  # stay in the document's Files tab.
  defp event("inventory_ai_forget_stored", _params, socket, _on_written),
    do: update_ai(socket, &%{&1 | stored_photos: []})

  defp event("inventory_ai_open_run", %{"run" => uuid}, socket, _on_written) do
    case own_run(socket, uuid) do
      %InventoryAIRun{status: "proposed"} = run ->
        update_ai(socket, &%{&1 | run: run, review: Review.new(run), picking: nil})

      %InventoryAIRun{} ->
        fail(socket, :not_proposed)

      nil ->
        fail(socket, :wrong_document)
    end
  end

  defp event("inventory_ai_close_proposal", _params, socket, _on_written),
    do: update_ai(socket, &%{&1 | run: nil, review: nil, picking: nil})

  defp event("inventory_ai_row", %{"row" => row} = params, socket, _on_written) do
    change_review(
      socket,
      row,
      &Review.set_inputs(&1, &2, params, socket.assigns.lines, socket.assigns.stock_map)
    )
  end

  defp event("inventory_ai_check", %{"row" => row}, socket, _on_written) do
    change_review(socket, row, fn review, key ->
      checked? =
        review
        |> Review.view(socket.assigns.lines, socket.assigns.stock_map)
        |> Enum.find_value(false, &(&1.key == key and &1.checked))

      Review.set_checked(review, key, not checked?)
    end)
  end

  # The placeholder of the alternatives' select: nothing chosen.
  defp event("inventory_ai_choose", %{"no" => ""}, socket, _on_written), do: socket

  defp event("inventory_ai_choose", %{"row" => row, "no" => no}, socket, _on_written) do
    change_review(socket, row, fn review, key ->
      with {:ok, number} <- parse_key(no),
           %{} = item <- Review.offered_item(review, key, number) do
        Review.choose(review, key, item)
      else
        _ -> {:error, :unknown_item}
      end
    end)
  end

  defp event("inventory_ai_pick", %{"row" => row}, socket, _on_written) do
    with %{review: %{}} <- socket.assigns.ai,
         {:ok, key} <- parse_key(row),
         true <- Enum.any?(socket.assigns.ai.review.rows, &(&1.key == key)) do
      update_ai(socket, &%{&1 | picking: key})
    else
      _ -> fail(socket, :unknown_row)
    end
  end

  defp event("inventory_ai_pick_cancel", _params, socket, _on_written),
    do: update_ai(socket, &%{&1 | picking: nil})

  defp event("inventory_ai_unmerge", %{"row" => row}, socket, _on_written),
    do: change_review(socket, row, &Review.unmerge/2)

  defp event("inventory_ai_apply", _params, socket, on_written) do
    case open_proposal(socket, socket.assigns.ai.run) do
      {:ok, run} -> apply_proposal(socket, run, on_written)
      {:error, reason} -> fail(socket, reason)
    end
  end

  defp event("inventory_ai_discard", %{"run" => uuid}, socket, _on_written) do
    with {:ok, _doc} <- live_draft(socket),
         %InventoryAIRun{} = run <- own_run(socket, uuid) || {:error, :wrong_document},
         {:ok, _run} <-
           InventoryAI.discard_run(run, socket.assigns.current_user,
             inventory_uuid: socket.assigns.doc.uuid
           ) do
      reload_runs(socket)
    else
      {:error, reason} -> socket |> fail(reason) |> reload_runs()
    end
  end

  defp event("inventory_ai_retry", %{"run" => uuid}, socket, _on_written) do
    with %InventoryAIRun{} = run <- own_run(socket, uuid) || {:error, :wrong_document},
         {:ok, new_run, pid} <-
           InventoryAI.retry_run(run, socket.assigns.current_user,
             inventory_uuid: socket.assigns.doc.uuid,
             locale: socket.assigns.locale
           ) do
      ref = Process.monitor(pid)

      socket
      |> update_ai(fn ai ->
        %{
          ai
          | started: MapSet.put(ai.started, new_run.uuid),
            monitors: Map.put(ai.monitors, ref, new_run.uuid)
        }
      end)
      |> reload_runs()
    else
      {:error, reason} -> socket |> fail(reason) |> reload_runs()
    end
  end

  defp event("inventory_ai_show_late", %{"run" => uuid}, socket, _on_written) do
    with %InventoryAIRun{} = run <- own_run(socket, uuid) || {:error, :wrong_document},
         {:ok, shown} <-
           InventoryAI.show_late_result(run, socket.assigns.current_user,
             inventory_uuid: socket.assigns.doc.uuid
           ) do
      socket
      |> update_ai(&%{&1 | run: shown, review: Review.new(shown), picking: nil})
      |> reload_runs()
    else
      {:error, reason} -> socket |> fail(reason) |> reload_runs()
    end
  end

  defp event(_event, _params, socket, _on_written), do: fail(socket, :unknown_event)

  defp apply_proposal(socket, run, on_written) do
    review = socket.assigns.ai.review
    rows = Review.apply_rows(review, socket.assigns.lines, socket.assigns.stock_map)

    case InventoryAI.apply_run(
           run,
           socket.assigns.base_fingerprint,
           socket.assigns.lines,
           rows,
           socket.assigns.current_user,
           inventory_uuid: socket.assigns.doc.uuid,
           locale: socket.assigns.locale
         ) do
      {:ok, %{document: doc, summary: summary}} ->
        socket
        |> on_written.(doc)
        |> update_ai(fn ai ->
          %{
            ai
            | run: nil,
              review: nil,
              picking: nil,
              notice:
                dngettext(
                  "default",
                  "Applied to the count sheet: %{count} row.",
                  "Applied to the count sheet: %{count} rows.",
                  summary.applied
                )
          }
        end)
        |> reload_runs()

      {:error, {:invalid_rows, errors}} ->
        socket
        |> update_ai(&%{&1 | review: Review.put_errors(&1.review, errors)})
        |> fail({:invalid_rows, errors})

      {:error, reason} ->
        socket |> fail(reason) |> reload_runs()
    end
  end

  # The run of the open proposal, read again through this document; none
  # open (it was applied or discarded, here or in another tab) is refused.
  defp open_proposal(_socket, nil), do: {:error, :not_proposed}

  defp open_proposal(socket, %InventoryAIRun{uuid: uuid}) do
    case own_run(socket, uuid) do
      %InventoryAIRun{} = run -> {:ok, run}
      nil -> {:error, :wrong_document}
    end
  end

  defp own_run(socket, uuid) when is_binary(uuid),
    do: InventoryAI.get_run(socket.assigns.doc.uuid, uuid)

  defp own_run(_socket, _uuid), do: nil

  # A change of the open proposal's table, on the row the event names.
  defp change_review(socket, row, fun) do
    with %{review: %{} = review} <- socket.assigns.ai,
         {:ok, key} <- parse_key(row),
         {:ok, review} <- fun.(review, key) do
      update_ai(socket, &%{&1 | review: review})
    else
      {:error, reason} -> fail(socket, reason)
      _ -> fail(socket, :unknown_row)
    end
  end

  # A row's key or an alternative's number as the browser sends it.
  defp parse_key(value) when is_integer(value), do: {:ok, value}

  defp parse_key(value) when is_binary(value) do
    case Integer.parse(value) do
      {key, ""} -> {:ok, key}
      _ -> :error
    end
  end

  defp parse_key(_value), do: :error

  # The upload form's place and catalogues: a place that is not text keeps
  # the one there is, a catalogue is one of those offered.
  defp put_form(socket, params) do
    ai = socket.assigns.ai
    known = MapSet.new(ai.catalogues, & &1.uuid)

    chosen =
      params
      |> Map.get("catalogue_uuids", [])
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and MapSet.member?(known, &1)))

    place =
      case Map.get(params, "place") do
        place when is_binary(place) -> place
        _ -> ai.place
      end

    socket = update_ai(socket, &%{&1 | place: place, catalogue_uuids: chosen})
    if chosen != ai.catalogue_uuids, do: count_catalogue(socket), else: socket
  end

  defp count_catalogue(socket) do
    ai = socket.assigns.ai
    count = CatalogueList.count(catalogue_uuids: ai.catalogue_uuids)
    assign(socket, :ai, %{ai | catalogue_count: count, max_items: Settings.max_items()})
  end

  defp ready(socket) do
    upload = socket.assigns.uploads[@upload]
    ai = socket.assigns.ai

    cond do
      upload.entries == [] and ai.stored_photos == [] -> {:error, :no_uploads}
      not Enum.all?(upload.entries, & &1.done?) -> {:error, :uploading}
      upload_errors(upload) != [] -> {:error, :upload_errors}
      Enum.any?(upload.entries, &(upload_errors(upload, &1) != [])) -> {:error, :upload_errors}
      Enum.any?(ai.runs, &(&1.status == "running")) -> {:error, :already_running}
      true -> :ok
    end
  end

  # What the run will be refused for without its photos, asked before the
  # photos are taken from the upload: a refused run leaves them there.
  defp check_start(socket) do
    ai = socket.assigns.ai

    InventoryAI.check_start(%{
      "place_label" => ai.place,
      "catalogue_uuids" => ai.catalogue_uuids,
      "photo_count" => length(ai.stored_photos) + length(socket.assigns.uploads[@upload].entries)
    })
  end

  # Every upload stored in the document's folder, in their order: the uuids
  # of those stored, and `{:error, :not_stored}` when one could not be (that
  # stops the run; the others stay in the folder).
  defp store_uploads(socket, doc) do
    results =
      consume_uploaded_entries(socket, @upload, fn %{path: path}, entry ->
        {:ok,
         InventoryAI.store_photo(
           doc,
           %{path: path, client_name: entry.client_name, client_type: entry.client_type},
           socket.assigns.current_user
         )}
      end)

    stored = for {:ok, file} <- results, do: file.uuid

    if Enum.all?(results, &match?({:ok, _file}, &1)),
      do: {stored, :ok},
      else: {stored, {:error, :not_stored}}
  end

  defp start(socket, doc, photos, store_result) do
    with :ok <- store_result,
         {:ok, run, pid} <-
           InventoryAI.start_run(
             doc,
             %{
               "place_label" => socket.assigns.ai.place,
               "photo_file_uuids" => photos,
               "catalogue_uuids" => socket.assigns.ai.catalogue_uuids
             },
             socket.assigns.current_user,
             locale: socket.assigns.locale
           ) do
      ref = Process.monitor(pid)

      socket
      |> update_ai(fn ai ->
        %{
          ai
          | place: "",
            stored_photos: [],
            started: MapSet.put(ai.started, run.uuid),
            monitors: Map.put(ai.monitors, ref, run.uuid)
        }
      end)
      |> reload_runs()
    else
      {:error, reason} -> refused_with(socket, photos, reason)
    end
  end

  # A run refused after its photos were stored: they are held for the next
  # Propose, and the error says where they are.
  defp refused_with(socket, [], reason), do: fail(socket, reason)

  # A held photo that no longer passes (trashed or moved out of the folder
  # since) would meet the same refusal on every Propose: nothing is held.
  defp refused_with(socket, _photos, :invalid_photos) do
    error =
      message(:invalid_photos) <>
        " " <> dgettext("default", "Choose the photos of this batch again.")

    update_ai(socket, &%{&1 | stored_photos: [], error: error})
  end

  defp refused_with(socket, photos, reason) do
    update_ai(
      socket,
      &%{&1 | stored_photos: photos, error: message(reason) <> " " <> kept_text()}
    )
  end

  defp kept_text,
    do:
      dgettext(
        "default",
        "The photos are kept in the Files tab: Propose again sends them without a new upload."
      )

  defp fail(socket, reason), do: update_ai(socket, &%{&1 | error: message(reason)})

  defp update_ai(socket, fun), do: assign(socket, :ai, fun.(socket.assigns.ai))

  defp message(:not_permitted),
    do: dgettext("default", "You may not change this stocktake.")

  defp message(:no_uploads),
    do: dgettext("default", "Upload the photos of the place first.")

  defp message(:uploading),
    do: dgettext("default", "Wait until every photo is uploaded.")

  defp message(:upload_errors),
    do: dgettext("default", "Remove the photos that cannot be uploaded first.")

  defp message(:unknown_row), do: dgettext("default", "This row is not in the proposal.")

  defp message(:unknown_item),
    do: dgettext("default", "This item is not offered for the row.")

  defp message(:inactive_item),
    do: dgettext("default", "This item is not active in the catalogue.")

  defp message(:unknown_event), do: dgettext("default", "Unknown action.")
  defp message(reason), do: InventoryAI.error_message(reason)

  # --- messages ----------------------------------------------------------------------------

  @doc """
  A message of the panel: a run's broadcast, the task monitor of a run this
  tab started, the item picker of a row. `:unhandled` for any other.
  """
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()} | :unhandled
  def handle_info({:inventory_ai_run, %{run_uuid: uuid, status: status}}, socket) do
    socket = reload_runs(socket)
    ai = socket.assigns.ai

    # A run this tab started opens by itself when its proposal comes.
    with true <- status == "proposed" and MapSet.member?(ai.started, uuid) and is_nil(ai.run),
         %InventoryAIRun{status: "proposed"} = run <- own_run(socket, uuid) do
      {:noreply, update_ai(socket, &%{&1 | run: run, review: Review.new(run), picking: nil})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    case Map.pop(socket.assigns.ai.monitors, ref) do
      {nil, _monitors} ->
        :unhandled

      {uuid, monitors} ->
        InventoryAI.interrupt_run(uuid)
        {:noreply, socket |> update_ai(&%{&1 | monitors: monitors}) |> reload_runs()}
    end
  end

  def handle_info({:item_picker_select, @picker_prefix <> _ = id, item}, socket) do
    {:noreply, pick(socket, id, item)}
  end

  def handle_info(_message, _socket), do: :unhandled

  defp pick(socket, id, item) do
    with :ok <- permitted(socket),
         %{review: %{} = review, picking: key} when is_integer(key) <- socket.assigns.ai,
         true <- id == picker_id(socket.assigns.ai.run, key) || {:error, :unknown_row},
         {:ok, facts} <- item_facts(item.uuid, socket.assigns.locale),
         {:ok, review} <- Review.choose(review, key, facts) do
      update_ai(socket, &%{&1 | review: review, picking: nil, error: nil})
    else
      {:error, reason} -> fail(socket, reason)
      _ -> socket
    end
  end

  # The facts of an item a person picked, read again from the catalogue: it
  # must be there and active.
  defp item_facts(uuid, locale) do
    case Catalogue.get_item(uuid) do
      %{status: "active"} = item ->
        {:ok,
         %{
           "no" => nil,
           "item_uuid" => item.uuid,
           "name" => WarehouseBrowser.localized_name(item, locale),
           "sku" => item.sku,
           "unit" => item.unit,
           "catalogue_uuid" => item.catalogue_uuid,
           "category_uuid" => item.category_uuid
         }}

      _ ->
        {:error, :inactive_item}
    end
  end

  defp picker_id(%InventoryAIRun{uuid: uuid}, key), do: "#{@picker_prefix}#{uuid}-#{key}"
  defp picker_id(_run, _key), do: nil

  # --- what the page shows outside the panel ----------------------------------------------

  @doc """
  The lines the photos counted below the stock (spec §11.4): a line with
  parts of runs whose total is under the stock of its item.
  """
  @spec below_stock_lines([map()], map()) :: [map()]
  def below_stock_lines(lines, stock_map) do
    for line <- lines,
        is_list(line["ai_parts"]) and line["ai_parts"] != [],
        stock = stock_qty(stock_map, line["item_uuid"]),
        counted = Lines.decimal(line["counted_quantity"]),
        counted && Lines.below_stock?(counted, stock) do
      %{
        line: line,
        stock: stock,
        counted: counted,
        places: line["ai_parts"] |> Enum.map(&place_text(&1["place"])) |> Enum.uniq()
      }
    end
  end

  defp stock_qty(stock_map, item_uuid) do
    case Map.get(stock_map, item_uuid) do
      %{quantity: quantity} -> Lines.decimal(quantity)
      _ -> nil
    end
  end

  @doc "The lines of the buffer counted from photos (lost when the lines are seeded again)."
  @spec photo_lines([map()]) :: non_neg_integer()
  def photo_lines(lines),
    do: Enum.count(lines, &(is_list(&1["ai_parts"]) and &1["ai_parts"] != []))

  @doc "The runs that are open: running, or waiting with a proposal."
  @spec open_runs(map()) :: [InventoryAIRun.t()]
  def open_runs(%{runs: runs}), do: Enum.filter(runs, &(&1.status in ["running", "proposed"]))

  # --- components ---------------------------------------------------------------------------

  @doc "The button next to Add item that opens the panel (spec §5.1)."
  attr(:ai, :map, required: true)
  attr(:doc, :any, required: true)

  def open_button(assigns) do
    ~H"""
    <button
      :if={visible?(@ai, @doc)}
      type="button"
      id="inventory-ai-open"
      phx-click="inventory_ai_toggle"
      class={["btn btn-sm", if(@ai.open?, do: "btn-active", else: "btn-outline")]}
    >
      <.icon name="hero-camera" class="w-4 h-4" />
      {dgettext("default", "Count from photos")}
    </button>
    """
  end

  defp visible?(ai, %InventoryDocument{status: "draft", deleted_at: nil}),
    do: ai.enabled? and ai.can_edit?

  defp visible?(_ai, _doc), do: false

  defp shown?(ai, %InventoryDocument{status: "draft", deleted_at: nil}), do: ai.can_edit?
  defp shown?(_ai, _doc), do: false

  # Anything the panel shows: without it the panel takes no room on the tab.
  defp content?(ai, doc) do
    ai.error != nil or ai.notice != nil or ai.runs != [] or (ai.open? and visible?(ai, doc)) or
      ai.review != nil
  end

  @doc """
  Above the count sheet: the runs of the document, the panel (when opened)
  and the open proposal.
  """
  attr(:ai, :map, required: true)
  attr(:doc, :any, required: true)
  attr(:uploads, :map, required: true)
  attr(:lines, :list, required: true)
  attr(:stock_map, :map, required: true)
  attr(:locale, :string, required: true)

  def panel(assigns) do
    ~H"""
    <div
      :if={shown?(@ai, @doc) and content?(@ai, @doc)}
      id="inventory-ai-area"
      class="mb-3 flex flex-col gap-3"
    >
      <div :if={@ai.error} id="inventory-ai-error" class="alert alert-error text-sm py-2">
        <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
        <span>{@ai.error}</span>
      </div>
      <div :if={@ai.notice} id="inventory-ai-notice" class="alert alert-success text-sm py-2">
        <.icon name="hero-check-circle" class="w-4 h-4" />
        <span>{@ai.notice}</span>
      </div>

      <.runs :if={@ai.runs != []} ai={@ai} />

      <.upload_panel :if={@ai.open? and visible?(@ai, @doc)} ai={@ai} uploads={@uploads} />

      <.proposal
        :if={@ai.review}
        ai={@ai}
        run={@ai.run}
        rows={Review.view(@ai.review, @lines, @stock_map)}
        locale={@locale}
      />
    </div>
    """
  end

  attr(:ai, :map, required: true)
  attr(:uploads, :map, required: true)

  defp upload_panel(assigns) do
    upload = assigns.uploads[@upload]
    entries = upload.entries
    ai = assigns.ai

    assigns =
      assigns
      |> assign(:upload, upload)
      |> assign(:uploading?, Enum.any?(entries, &(not &1.done?)))
      |> assign(:running?, Enum.any?(ai.runs, &(&1.status == "running")))
      |> assign(:too_many_items?, too_many_items?(ai))
      |> assign(
        :ready?,
        (entries != [] or ai.stored_photos != []) and Enum.all?(entries, & &1.done?) and
          upload_errors(upload) == [] and
          Enum.all?(entries, &(upload_errors(upload, &1) == [])) and
          not Enum.any?(ai.runs, &(&1.status == "running")) and not too_many_items?(ai)
      )

    ~H"""
    <div id="inventory-ai-panel" class="card bg-base-200/60 border border-base-300">
      <div class="card-body p-4 gap-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="font-semibold flex items-center gap-2">
            <.icon name="hero-camera" class="w-4 h-4" />
            {dgettext("default", "Count from photos")}
          </h3>
          <span class="text-xs text-base-content/60">
            {dgettext("default", "One upload is one batch of one place.")}
          </span>
        </div>

        <p id="inventory-ai-privacy" class="text-xs text-base-content/60">
          <.icon name="hero-shield-exclamation" class="w-3.5 h-3.5 inline" />
          {dgettext(
            "default",
            "The photos are sent to an outside AI service: photograph the shelves, not people."
          )}
        </p>

        <form
          id="inventory-ai-upload-form"
          phx-change="inventory_ai_change"
          phx-submit="inventory_ai_run"
          class="flex flex-col gap-3"
        >
          <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
            <label class="flex flex-col gap-1">
              <span class="text-sm font-medium">{dgettext("default", "Place")}</span>
              <input
                type="text"
                id="inventory-ai-place"
                name="place"
                value={@ai.place}
                maxlength="200"
                placeholder={dgettext("default", "Shelf 2, top (optional)")}
                class="input input-sm w-full"
                phx-debounce="300"
              />
            </label>

            <fieldset :if={@ai.catalogues != []} class="flex flex-col gap-1">
              <legend class="text-sm font-medium mb-1">
                {dgettext("default", "What is on these photos (optional)")}
              </legend>
              <div id="inventory-ai-catalogues" class="flex flex-wrap gap-x-4 gap-y-1">
                <label
                  :for={catalogue <- @ai.catalogues}
                  class="flex items-center gap-2 text-sm cursor-pointer"
                >
                  <input
                    type="checkbox"
                    name="catalogue_uuids[]"
                    value={catalogue.uuid}
                    checked={catalogue.uuid in @ai.catalogue_uuids}
                    class="checkbox checkbox-sm"
                  />
                  <span>{catalogue.name}</span>
                </label>
              </div>
              <span class="text-xs text-base-content/60">
                {dgettext("default", "None chosen: every catalogue.")}
              </span>
            </fieldset>
          </div>

          <div
            id="inventory-ai-upload"
            phx-drop-target={@upload.ref}
            class="border border-dashed border-base-300 rounded-box p-3 flex flex-col gap-2 bg-base-100"
          >
            <.live_file_input upload={@upload} class="file-input file-input-sm w-full" />
            <span class="text-xs text-base-content/60">
              {dngettext(
                "default",
                "Up to %{count} photo, at most 20 MB.",
                "Up to %{count} photos, at most 20 MB each.",
                @upload.max_entries
              )}
            </span>
            <p :for={error <- upload_errors(@upload)} class="text-xs text-error">
              {upload_error(error)}
            </p>

            <ul :if={@upload.entries != []} id="inventory-ai-uploads" class="flex flex-col gap-1">
              <li
                :for={entry <- @upload.entries}
                id={"inventory-ai-entry-#{entry.ref}"}
                class="flex items-center gap-2 text-xs"
              >
                <span class="truncate flex-1">{entry.client_name}</span>
                <progress class="progress progress-primary w-24" value={entry.progress} max="100">
                  {entry.progress}%
                </progress>
                <span class="tabular-nums w-10 text-right">{entry.progress}%</span>
                <button
                  type="button"
                  phx-click="inventory_ai_cancel_upload"
                  phx-value-ref={entry.ref}
                  class="btn btn-ghost btn-xs"
                  aria-label={dgettext("default", "Remove")}
                >
                  <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                </button>
                <span :for={error <- upload_errors(@upload, entry)} class="text-error">
                  {upload_error(error)}
                </span>
              </li>
            </ul>
          </div>

          <div
            :if={@ai.stored_photos != []}
            id="inventory-ai-stored"
            class="flex flex-wrap items-center gap-2 text-xs text-base-content/70"
          >
            <.icon name="hero-folder" class="w-3.5 h-3.5" />
            <span>
              {dngettext(
                "default",
                "%{count} photo stored in the Files tab goes with this batch.",
                "%{count} photos stored in the Files tab go with this batch.",
                length(@ai.stored_photos)
              )}
            </span>
            <button
              type="button"
              id="inventory-ai-forget-stored"
              phx-click="inventory_ai_forget_stored"
              class="btn btn-ghost btn-xs"
            >
              {dgettext("default", "Do not send them")}
            </button>
          </div>

          <p :if={@uploading?} id="inventory-ai-uploading" class="text-xs text-warning">
            {dgettext("default", "Do not leave the page while the photos upload.")}
          </p>

          <p :if={@too_many_items?} id="inventory-ai-too-many-items" class="text-xs text-warning">
            {dgettext(
              "default",
              "The chosen catalogues hold %{count} items, more than %{max}: choose fewer catalogues.",
              count: @ai.catalogue_count,
              max: @ai.max_items
            )}
          </p>

          <div class="flex flex-wrap items-center gap-2">
            <button
              type="submit"
              id="inventory-ai-run"
              class="btn btn-primary btn-sm"
              disabled={not @ready?}
            >
              <.icon name="hero-sparkles" class="w-4 h-4" />
              {dgettext("default", "Propose")}
            </button>
            <span :if={@running?} class="text-xs text-base-content/60">
              {dgettext("default", "Another batch is being read.")}
            </span>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp too_many_items?(%{catalogue_count: count, max_items: max})
       when is_integer(count) and is_integer(max),
       do: count > max

  defp too_many_items?(_ai), do: false

  defp upload_error(:too_large), do: dgettext("default", "The photo is larger than 20 MB.")
  defp upload_error(:not_accepted), do: dgettext("default", "Only photos can be uploaded.")

  defp upload_error(:too_many_files),
    do: dgettext("default", "Too many photos for one batch.")

  defp upload_error(_error), do: dgettext("default", "The photo cannot be uploaded.")

  attr(:ai, :map, required: true)

  defp runs(assigns) do
    ~H"""
    <details
      id="inventory-ai-runs"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
      class="collapse collapse-arrow bg-base-100 border border-base-200"
    >
      <summary class="collapse-title min-h-0 py-2 text-sm font-medium">
        {dgettext("default", "Photo batches (%{count})", count: length(@ai.runs))}
        <span
          :for={run <- Enum.filter(@ai.runs, &(&1.status == "running"))}
          id="inventory-ai-running"
          class="ml-2 text-xs text-base-content/60"
        >
          <span class="loading loading-spinner loading-xs" />
          {dngettext(
            "default",
            "The AI is looking at %{count} photo…",
            "The AI is looking at %{count} photos…",
            length(run.photo_file_uuids)
          )}
        </span>
      </summary>
      <div class="collapse-content px-2">
        <p class="text-xs text-base-content/60 pb-2">
          {dgettext(
            "default",
            "Reading takes 20-40 seconds as a rule. The page may be closed: the answer is kept and shown here."
          )}
        </p>
        <ul class="flex flex-col divide-y divide-base-200">
          <li
            :for={run <- @ai.runs}
            id={"inventory-ai-run-#{run.uuid}"}
            class="py-2 flex flex-wrap items-center gap-2 text-sm"
          >
            <span class="font-medium">{place_text(run.place_label)}</span>
            <span class="text-xs text-base-content/60">
              {photo_count(run)}
            </span>
            <span class={["badge badge-sm", status_class(run.status)]}>{status_text(run.status)}</span>
            <span class="text-xs text-base-content/60">
              {UserNames.label(@ai.users, run.created_by_uuid)} · {Calendar.strftime(
                run.inserted_at,
                "%Y-%m-%d %H:%M"
              )}
            </span>
            <span :if={below_stock_count(run) > 0} class="badge badge-sm badge-warning">
              {dgettext("default", "%{count} below the stock", count: below_stock_count(run))}
            </span>
            <span :if={run.status == "error" and run.error} class="text-xs text-error w-full">
              {run.error}
            </span>
            <span class="flex-1" />
            <button
              :if={run.status == "proposed" and (is_nil(@ai.run) or @ai.run.uuid != run.uuid)}
              type="button"
              id={"inventory-ai-open-run-#{run.uuid}"}
              phx-click="inventory_ai_open_run"
              phx-value-run={run.uuid}
              class="btn btn-xs btn-primary"
            >
              {dgettext("default", "Open")}
            </button>
            <button
              :if={run.status == "error"}
              type="button"
              id={"inventory-ai-retry-#{run.uuid}"}
              phx-click="inventory_ai_retry"
              phx-value-run={run.uuid}
              class="btn btn-xs"
            >
              <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
              {dgettext("default", "Retry")}
            </button>
            <span :if={run.status == "error" and run.late_answer?} class="flex items-center gap-2">
              <span
                :if={MapSet.member?(@ai.retaken, run.uuid)}
                id={"inventory-ai-late-warning-#{run.uuid}"}
                class="text-xs text-warning"
              >
                {dgettext("default", "This place may have been photographed again since.")}
              </span>
              <button
                type="button"
                id={"inventory-ai-late-#{run.uuid}"}
                phx-click="inventory_ai_show_late"
                phx-value-run={run.uuid}
                class="btn btn-xs btn-ghost"
              >
                {dgettext("default", "Show the late answer")}
              </button>
            </span>
            <button
              :if={run.status in ["running", "proposed", "error"]}
              type="button"
              id={"inventory-ai-discard-#{run.uuid}"}
              phx-click="inventory_ai_discard"
              phx-value-run={run.uuid}
              class="btn btn-xs btn-ghost"
            >
              {dgettext("default", "Discard")}
            </button>
          </li>
        </ul>
      </div>
    </details>
    """
  end

  defp below_stock_count(%InventoryAIRun{status: "applied", decisions: %{"rows" => rows}})
       when is_list(rows) do
    Enum.count(rows, fn row ->
      counted = Lines.decimal(row["counted_quantity"])
      counted && Lines.below_stock?(counted, Lines.decimal(row["stock"]))
    end)
  end

  defp below_stock_count(_run), do: 0

  defp status_class("running"), do: "badge-info"
  defp status_class("proposed"), do: "badge-primary"
  defp status_class("error"), do: "badge-error"
  defp status_class("applied"), do: "badge-success"
  defp status_class(_status), do: "badge-ghost"

  defp status_text("running"), do: dgettext("default", "Reading")
  defp status_text("proposed"), do: dgettext("default", "Proposed")
  defp status_text("error"), do: dgettext("default", "Failed")
  defp status_text("applied"), do: dgettext("default", "Applied")
  defp status_text("discarded"), do: dgettext("default", "Discarded")
  defp status_text(status), do: status

  defp photo_count(run) do
    count = length(run.photo_file_uuids)
    dngettext("default", "%{count} photo", "%{count} photos", count)
  end

  defp place_text(place) when is_binary(place) and place != "", do: place
  defp place_text(_place), do: dgettext("default", "no place given")

  attr(:ai, :map, required: true)
  attr(:run, :any, required: true)
  attr(:rows, :list, required: true)
  attr(:locale, :string, required: true)

  defp proposal(assigns) do
    result = assigns.run.result || %{}

    assigns =
      assigns
      |> assign(:result, result)
      |> assign(:checked, Enum.count(assigns.rows, & &1.checked))

    ~H"""
    <div id={"inventory-ai-proposal-#{@run.uuid}"} class="card bg-base-100 border border-primary/30 shadow-sm">
      <div class="card-body p-4 gap-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="font-semibold">
            {dgettext("default", "Proposal: %{place}", place: place_text(@run.place_label))}
            <span class="text-xs font-normal text-base-content/60 ml-2">
              {photo_count(@run)}
              <span :if={@run.model}>· {@run.model}</span>
            </span>
          </h3>
          <button type="button" phx-click="inventory_ai_close_proposal" class="btn btn-ghost btn-xs">
            {dgettext("default", "Hide")}
          </button>
        </div>

        <div :if={@rows == []} class="alert text-sm py-2">
          {dgettext("default", "No warehouse items were found on the photos.")}
        </div>

        <p :if={(@result["skipped_photos"] || []) != []} class="text-xs text-warning">
          {dgettext("default", "Photos that could not be read and were left out: %{count}",
            count: length(@result["skipped_photos"])
          )}
        </p>
        <p :if={(@result["warnings"] || []) != []} class="text-xs text-base-content/60">
          {dgettext("default", "Values of the answer corrected by the check: %{count}",
            count: length(@result["warnings"])
          )}
        </p>

        <div :if={@rows != []} class="overflow-x-auto">
          <table class="table table-sm w-full">
            <thead>
              <tr>
                <th class="w-8"></th>
                <th>{dgettext("default", "Photos")}</th>
                <th>{dgettext("default", "What the AI sees")}</th>
                <th>{dgettext("default", "Item")}</th>
                <th class="w-36">{dgettext("default", "Quantity")}</th>
                <th>{dgettext("default", "How it was counted")}</th>
                <th>{dgettext("default", "Confidence")}</th>
                <th>{dgettext("default", "In the sheet now")}</th>
                <th>{dgettext("default", "Becomes")}</th>
              </tr>
            </thead>
            <tbody>
              <.proposal_row :for={row <- @rows} row={row} run={@run} ai={@ai} locale={@locale} />
            </tbody>
          </table>
        </div>

        <p class="text-xs text-base-content/60">
          {dgettext(
            "default",
            "Your edits in this table are kept until Apply; after a reload the proposal is shown again as the AI made it."
          )}
        </p>

        <div class="flex flex-wrap items-center gap-2">
          <button
            :if={@rows != []}
            type="button"
            id="inventory-ai-apply"
            phx-click="inventory_ai_apply"
            class="btn btn-primary btn-sm"
            disabled={@checked == 0}
          >
            <.icon name="hero-check" class="w-4 h-4" />
            {dgettext("default", "Apply ticked rows (%{count})", count: @checked)}
          </button>
          <button
            type="button"
            id="inventory-ai-discard"
            phx-click="inventory_ai_discard"
            phx-value-run={@run.uuid}
            class="btn btn-ghost btn-sm"
          >
            {dgettext("default", "Discard")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:run, :any, required: true)
  attr(:ai, :map, required: true)
  attr(:locale, :string, required: true)

  defp proposal_row(assigns) do
    ~H"""
    <tr
      id={"inventory-ai-row-#{@row.key}"}
      class={["align-top", @row.checked && "bg-primary/5", @row.kind == :measured && "bg-warning/10"]}
    >
      <td>
        <input
          type="checkbox"
          id={"inventory-ai-check-#{@row.key}"}
          class="checkbox checkbox-sm checkbox-primary"
          checked={@row.checked}
          disabled={is_nil(@row.item)}
          phx-click="inventory_ai_check"
          phx-value-row={@row.key}
        />
      </td>
      <td>
        <div class="flex flex-wrap gap-1">
          <img
            :for={uuid <- photo_uuids(@run, @row.photos)}
            src={URLSigner.signed_url(uuid, "thumbnail")}
            class="w-10 h-10 object-cover rounded"
            alt=""
            loading="lazy"
          />
        </div>
      </td>
      <td class="text-xs max-w-48">{@row.description}</td>
      <td class="min-w-56">
        <%= if @row.item do %>
          <div class="font-medium text-sm">{@row.item["name"]}</div>
          <div class="text-xs text-base-content/50 font-mono">{@row.item["sku"]}</div>
        <% else %>
          <div class="text-sm text-warning">{dgettext("default", "Choose an item")}</div>
        <% end %>
        <form
          :if={@row.alternatives != []}
          id={"inventory-ai-choose-#{@row.key}"}
          phx-change="inventory_ai_choose"
          class="mt-1"
        >
          <input type="hidden" name="row" value={@row.key} />
          <select name="no" class="select select-xs w-full">
            <option value="">{dgettext("default", "— other proposed item —")}</option>
            <option :for={item <- @row.alternatives} value={item["no"]}>
              {item["name"]} {sku_suffix(item["sku"])}
            </option>
          </select>
        </form>
        <%= if @ai.picking == @row.key do %>
          <div class="mt-1 flex items-center gap-1">
            <div class="flex-1">
              <.live_component
                module={ItemPicker}
                id={"inventory-ai-picker-#{@run.uuid}-#{@row.key}"}
                statuses={["active"]}
                item_types={["goods"]}
                include_internal={true}
                locale={@locale}
                show_sku={true}
                show_unit={true}
              />
            </div>
            <button type="button" phx-click="inventory_ai_pick_cancel" class="btn btn-ghost btn-xs">
              <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
            </button>
          </div>
        <% else %>
          <button
            type="button"
            id={"inventory-ai-pick-#{@row.key}"}
            phx-click="inventory_ai_pick"
            phx-value-row={@row.key}
            class="btn btn-ghost btn-xs mt-1"
          >
            <.icon name="hero-magnifying-glass" class="w-3.5 h-3.5" />
            {dgettext("default", "Another item")}
          </button>
        <% end %>
        <button
          :if={@row.merged?}
          type="button"
          id={"inventory-ai-unmerge-#{@row.key}"}
          phx-click="inventory_ai_unmerge"
          phx-value-row={@row.key}
          class="btn btn-ghost btn-xs mt-1"
        >
          <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" />
          {dgettext("default", "Undo the merge")}
        </button>
      </td>
      <td>
        <form
          id={"inventory-ai-inputs-#{@row.key}"}
          phx-change="inventory_ai_row"
          phx-submit="inventory_ai_row"
          class="flex flex-col gap-1"
        >
          <input type="hidden" name="row" value={@row.key} />
          <label :if={@row.kind == :package_size or @row.package_size != ""} class="flex flex-col">
            <span class="text-xs text-base-content/60">
              {dgettext("default", "Units per package")}
            </span>
            <.decimal_input
              id={"inventory-ai-package-#{@row.key}"}
              name="package_size"
              value={@row.package_size}
              class="input-xs"
              phx-debounce="blur"
            />
          </label>
          <label class="flex flex-col">
            <span :if={@row.kind in [:package_size, :quantity]} class="text-xs text-base-content/60">
              {if @row.kind == :package_size,
                do: dgettext("default", "or enter the quantity"),
                else: dgettext("default", "Enter the quantity")}
            </span>
            <.decimal_input
              id={"inventory-ai-quantity-#{@row.key}"}
              name="quantity"
              value={@row.quantity}
              class={["input-xs", @row.kind == :measured && "input-warning"]}
              phx-debounce="blur"
            />
          </label>
          <span :if={@row.kind == :measured} class="text-xs text-warning">
            {dgettext("default", "Check the quantity")}
          </span>
          <span :if={@row.item} class="text-xs text-base-content/50">
            {WarehouseBrowser.unit_label(@row.item["unit"])}
          </span>
          <select :if={length(@row.actions) > 1} name="action" class="select select-xs">
            <option :for={action <- @row.actions} value={action} selected={action == @row.action}>
              {action_text(action)}
            </option>
          </select>
          <span :for={{field, error} <- @row.errors} class="text-xs text-error">
            {field_error(field, error)}
          </span>
        </form>
      </td>
      <td class="text-xs max-w-56">
        <div :for={formula <- @row.formulas} class="font-mono">{formula}</div>
        <div :if={@row.ai_basis != ""} class="text-base-content/60">{@row.ai_basis}</div>
      </td>
      <td class="text-xs">
        <div>
          {dpgettext("default", "confidence", "item")}: {confidence_text(@row.match_confidence)}
        </div>
        <div>
          {dpgettext("default", "confidence", "count")}: {confidence_text(@row.count_confidence)}
        </div>
      </td>
      <td class="text-xs">
        <.line_now line={@row.line} />
      </td>
      <td class="text-xs">
        <div :if={@row.total} class="font-semibold tabular-nums">
          {StockLedger.format_quantity(@row.total)}
        </div>
        <div :if={@row.stock} class="text-base-content/60">
          {dpgettext("default", "proposal row", "stock")}: {StockLedger.format_quantity(@row.stock)}
        </div>
        <div :if={@row.starred?} class="text-base-content/60">★ {dgettext("default", "on this warehouse")}</div>
        <div :if={not @row.checked and @row.reasons != []} class="text-base-content/60 mt-1">
          {Enum.map_join(@row.reasons, "; ", &reason_text/1)}
        </div>
        <div
          :if={@row.checked and :sharply_below_stock in @row.reasons}
          id={"inventory-ai-far-below-#{@row.key}"}
          class="text-warning mt-1"
        >
          {reason_text(:sharply_below_stock)}
        </div>
      </td>
    </tr>
    """
  end

  attr(:line, :any, required: true)

  defp line_now(%{line: nil} = assigns) do
    ~H"""
    <span class="text-base-content/50">{dgettext("default", "not in the sheet")}</span>
    """
  end

  defp line_now(%{line: %{kind: :repeated}} = assigns) do
    ~H"""
    <span class="text-error">
      {dgettext("default", "Two lines of this item in the sheet: remove one first.")}
    </span>
    """
  end

  defp line_now(assigns) do
    ~H"""
    <div class="tabular-nums">
      {format_or_dash(@line.counted)}
      <span class="text-base-content/60">({counted_by_text(@line.counted_by)})</span>
    </div>
    <div :if={@line.kind == :seeded} class="text-base-content/60">
      <%= if @line.seeded && @line.stock && not Decimal.eq?(@line.seeded, @line.stock) do %>
        {dgettext("default", "By the stock at seeding: %{seeded}, now %{stock}; not counted.",
          seeded: StockLedger.format_quantity(@line.seeded),
          stock: StockLedger.format_quantity(@line.stock)
        )}
      <% else %>
        {dgettext("default", "By the stock; not counted.")}
      <% end %>
    </div>
    <div :if={@line.kind == :ai} class="text-base-content/60">
      {dgettext("default", "Already %{total}: %{parts}",
        total: format_or_dash(@line.counted),
        parts: ai_parts_text(@line)
      )}
    </div>
    <div :if={@line.kind == :manual} class="text-base-content/60">
      {dgettext("default", "Counted by hand: %{quantity}", quantity: format_or_dash(@line.counted))}
      <span :if={@line.history != []}>
        · {dgettext("default", "earlier from photos: %{parts}", parts: parts_text(@line.history))}
      </span>
    </div>
    """
  end

  defp ai_parts_text(line) do
    base =
      case {line.base, line.base_source} do
        {%Decimal{} = base, source} ->
          if Decimal.eq?(base, 0), do: [], else: [base_text(source, base)]

        _ ->
          []
      end

    Enum.join(base ++ [parts_text(line.parts)], ", ")
  end

  defp base_text("stock", base),
    do:
      dgettext("default", "by the stock %{quantity}", quantity: StockLedger.format_quantity(base))

  defp base_text(_source, base),
    do: dgettext("default", "by hand %{quantity}", quantity: StockLedger.format_quantity(base))

  defp parts_text(parts),
    do:
      Enum.map_join(parts, ", ", fn {place, qty} ->
        "#{place_text(place)} #{format_or_dash(qty)}"
      end)

  defp format_or_dash(%Decimal{} = value), do: StockLedger.format_quantity(value)
  defp format_or_dash(_value), do: "—"

  defp counted_by_text("stock"), do: dgettext("default", "by the stock")
  defp counted_by_text("manual"), do: dgettext("default", "by hand")
  defp counted_by_text("ai"), do: dgettext("default", "from photos")
  defp counted_by_text(_), do: dgettext("default", "not marked")

  defp photo_uuids(run, numbers) do
    numbers
    |> Enum.map(&Enum.at(run.photo_file_uuids, &1 - 1))
    |> Enum.reject(&is_nil/1)
  end

  defp action_text("new"), do: dgettext("default", "New line")
  defp action_text("replace"), do: dgettext("default", "Replace")
  defp action_text("add"), do: dpgettext("default", "line action", "Add")
  defp action_text("replace_part"), do: dgettext("default", "Replace this place's part")
  defp action_text("add_part"), do: dgettext("default", "Add as another part")
  defp action_text("replace_all"), do: dgettext("default", "Replace all")
  defp action_text(action), do: action

  defp confidence_text("high"), do: dpgettext("default", "confidence", "high")
  defp confidence_text("medium"), do: dpgettext("default", "confidence", "medium")
  defp confidence_text(_low), do: dpgettext("default", "confidence", "low")

  defp reason_text(:no_item), do: dgettext("default", "choose an item")
  defp reason_text(:low_match), do: dgettext("default", "the item is not certain")
  defp reason_text(:low_count), do: dgettext("default", "the count is not certain")
  defp reason_text(:measured), do: dgettext("default", "check the quantity")
  defp reason_text(:needs_input), do: dgettext("default", "enter the quantity")
  defp reason_text(:typed), do: dgettext("default", "the quantity was typed")
  defp reason_text(:sharply_below_stock), do: dgettext("default", "far below the stock")

  defp reason_text(:new_without_star),
    do: dgettext("default", "a new item, not held on this warehouse")

  defp reason_text(:manual_line), do: dgettext("default", "the line was counted by hand")
  defp reason_text(:repeated_line), do: dgettext("default", "two lines of this item")
  defp reason_text(_reason), do: ""

  defp field_error("quantity", :negative),
    do: dgettext("default", "The quantity cannot be negative.")

  defp field_error("quantity", _error), do: dgettext("default", "Enter the quantity as a number.")

  defp field_error("package_size", _error),
    do: dgettext("default", "Enter the units per package as a number above 0.")

  defp field_error("item_uuid", _error),
    do: dgettext("default", "This item cannot be applied: choose another.")

  defp field_error("action", _error), do: dgettext("default", "This rule does not fit the line.")
  defp field_error(_field, _error), do: dgettext("default", "This row cannot be applied.")

  # An item's SKU after its name, in brackets; nothing for an item without one.
  defp sku_suffix(sku) when is_binary(sku) do
    case String.trim(sku) do
      "" -> nil
      sku -> "(#{sku})"
    end
  end

  defp sku_suffix(_sku), do: nil

  @doc """
  Before Conduct (spec §11.4, §11.5): the lines the photos counted below
  the stock, and the batches still open. It does not block the posting.
  """
  attr(:lines, :list, required: true)
  attr(:stock_map, :map, required: true)
  attr(:names, :map, required: true)
  attr(:ai, :map, required: true)

  def conduct_summary(assigns) do
    assigns =
      assigns
      |> assign(:below, below_stock_lines(assigns.lines, assigns.stock_map))
      |> assign(:open, open_runs(assigns.ai))

    ~H"""
    <div
      :if={@below != [] or @open != []}
      id="inventory-ai-conduct-summary"
      class="alert alert-warning flex flex-col items-start gap-1 text-sm"
    >
      <div :if={@below != []} id="inventory-ai-below-stock" class="w-full">
        <div class="font-medium">
          {dngettext(
            "default",
            "%{count} item counted from photos is below the stock:",
            "%{count} items counted from photos are below the stock:",
            length(@below)
          )}
        </div>
        <ul class="list-disc pl-5">
          <li :for={entry <- @below}>
            {Map.get(@names, entry.line["item_uuid"]) || entry.line["name"]} — {dgettext(
              "default",
              "stock %{stock}, counted %{counted} (%{places})",
              stock: StockLedger.format_quantity(entry.stock),
              counted: StockLedger.format_quantity(entry.counted),
              places: Enum.join(entry.places, ", ")
            )}
          </li>
        </ul>
      </div>
      <div :if={@open != []} id="inventory-ai-open-runs">
        {dgettext(
          "default",
          "Photo batches still open: %{count}. Conducting closes them without applying.",
          count: length(@open)
        )}
      </div>
    </div>
    """
  end

  @doc "In the warehouse-change modal: what the new seed takes away (spec §11.5)."
  attr(:lines, :list, required: true)
  attr(:ai, :map, required: true)

  def location_warning(assigns) do
    assigns =
      assigns
      |> assign(:photo_lines, photo_lines(assigns.lines))
      |> assign(:open, open_runs(assigns.ai))

    ~H"""
    <div
      :if={@photo_lines > 0 or @open != []}
      id="inventory-ai-location-warning"
      class="alert alert-warning text-sm"
    >
      <span :if={@photo_lines > 0}>
        {dngettext(
          "default",
          "%{count} line counted from photos will be lost.",
          "%{count} lines counted from photos will be lost.",
          @photo_lines
        )}
      </span>
      <span :if={@open != []}>
        {dgettext("default", "The open photo batches (%{count}) will be closed.",
          count: length(@open)
        )}
      </span>
    </div>
    """
  end
end
