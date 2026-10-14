defmodule PhoenixKitWarehouse.API.Write do
  @moduledoc """
  The document tools of the warehouse API: `warehouse.receive_stock`,
  `warehouse.set_stock` and `warehouse.issue_stock`.

  Each call is one document with many lines, created and posted in one
  transaction by `create_and_post/2` of the document's context, so a refused call
  leaves no draft and burns no document number. The flow:

    1. `prepare/2` reads the whole request without writing: location, catalogue
       scope, basis (`external_ref` / `source`), note, reason, lines. Every
       problem is collected; if there is any, nothing is posted (warehouse
       documents are atomic) and the answer is `422 validation_failed`
       with `context.errors[{path, code, message}]`.
    2. `execute/2` posts, and answers the document, a per-line `{from, to}`
       and a summary. A repeated `external_ref` answers `status: "skipped"`
       with the existing document and writes nothing.

  Before step 1, `run/3` looks for a posted document with the request's
  `external_ref`: such a request is a retry and is answered from that
  document (`answer_retry/3`), so a product trashed or a default warehouse
  changed since the first call cannot turn it into a 422. The posting layer
  compares nothing, so the answer also says when the lines are not the posted
  ones (`external_ref_lines_differ`).

  Handlers are called as `f.(input, ctx)` with a string-keyed `input` already
  validated against the closed schema of the tool.
  """

  require Logger

  alias PhoenixKitWarehouse.API.Audit
  alias PhoenixKitWarehouse.API.Lines
  alias PhoenixKitWarehouse.API.Quantity
  alias PhoenixKitWarehouse.API.Refs
  alias PhoenixKitWarehouse.API.Source
  alias PhoenixKitWarehouse.API.Warehouses
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.PostingSupport
  alias PhoenixKitWarehouse.StockLedger

  @max_note 1000

  @kinds %{
    receipt: %{
      type: "goods_receipt",
      schema: GoodsReceipt,
      minimum: :positive,
      unit_value: true
    },
    inventory: %{
      type: "inventory",
      schema: InventoryDocument,
      minimum: :zero,
      unit_value: false
    },
    issue: %{
      type: "goods_issue",
      schema: GoodsIssue,
      minimum: :positive,
      unit_value: false
    }
  }

  @type result ::
          {:ok, map()}
          | {:ok, map(), [map()]}
          | {:error, atom(), String.t(), map()}

  @doc "`warehouse.receive_stock`: a goods receipt with many lines."
  @spec receive_stock(map(), map()) :: result()
  def receive_stock(input, ctx), do: run(:receipt, input, ctx)

  @doc """
  `warehouse.set_stock`: a stocktake document that sets the listed items to
  absolute quantities (zero allowed); other stock rows are untouched.
  """
  @spec set_stock(map(), map()) :: result()
  def set_stock(input, ctx), do: run(:inventory, input, ctx)

  @doc """
  `warehouse.issue_stock`: a goods issue (write-off) with many lines. All
  lines are checked against stock under row locks; every short line is
  reported in one `insufficient_stock` answer and nothing is posted.
  """
  @spec issue_stock(map(), map()) :: result()
  def issue_stock(input, ctx), do: run(:issue, input, ctx)

  defp run(kind, input, ctx) do
    case posted_by_reference(kind, input) do
      nil ->
        run_new(kind, input, ctx)

      doc ->
        if Map.get(ctx, :dry_run?, false),
          do: preview_retry(kind, input, doc),
          else: answer_retry(kind, input, doc)
    end
  end

  defp run_new(kind, input, ctx) do
    case prepare(kind, input) do
      {:ok, request} ->
        if Map.get(ctx, :dry_run?, false), do: preview(request), else: execute(request, ctx)

      {:error, errors} ->
        refuse_request(errors)
    end
  end

  # A refusal as the executor expects it: `{:error, code, message, context}`.
  defp fail(code, message, context), do: {:error, code, message, context}

  defp refuse_request(errors) do
    fail(
      :validation_failed,
      "Nothing was posted: #{length(errors)} problem(s) found in the request.",
      %{errors: errors, posted: false}
    )
  end

  # --- prepare: read the request, write nothing ------------------------------

  defp prepare(kind, input) do
    spec = Map.fetch!(@kinds, kind)
    catalogue = Refs.catalogue_scope(input["catalogue_id"], :write)

    catalogue_uuid =
      case catalogue do
        {:ok, uuid} -> uuid
        {:error, _error} -> nil
      end

    parts = [
      location: Warehouses.resolve(input["location_id"], :write),
      catalogue: catalogue,
      basis: Source.basis(kind, input),
      note: clean_note(input["note"]),
      reason: reason(kind, input["reason"]),
      lines:
        Lines.prepare(input["lines"],
          minimum: spec.minimum,
          unit_value: spec.unit_value,
          catalogue_uuid: catalogue_uuid
        )
    ]

    errors =
      Enum.flat_map(parts, fn
        {_name, {:error, error}} -> List.wrap(error)
        {_name, {:ok, _value}} -> []
      end)

    case errors do
      [] -> {:ok, build(kind, parts)}
      errors -> {:error, errors}
    end
  end

  defp build(kind, parts) do
    {:ok, location_uuid} = parts[:location]
    {:ok, basis} = parts[:basis]
    {:ok, note} = parts[:note]
    {:ok, reason} = parts[:reason]
    {:ok, lines} = parts[:lines]

    %{
      kind: kind,
      location_uuid: location_uuid,
      lines: lines,
      external_ref: basis.external_ref,
      order_uuid: basis.order_uuid,
      note: note,
      reason: reason
    }
  end

  defp clean_note(nil), do: {:ok, nil}

  defp clean_note(note) when is_binary(note) do
    trimmed = String.trim(note)

    cond do
      trimmed == "" ->
        {:ok, nil}

      String.length(trimmed) > @max_note ->
        {:error, note_error("note must be at most #{@max_note} characters.")}

      true ->
        {:ok, trimmed}
    end
  end

  defp clean_note(_other), do: {:error, note_error("note must be a string.")}

  defp note_error(message), do: %{path: "note", code: "validation_failed", message: message}

  defp reason(:issue, value) do
    if value in GoodsIssue.reasons() do
      {:ok, value}
    else
      {:error,
       %{
         path: "reason",
         code: "validation_failed",
         message: "reason must be one of: #{Enum.join(GoodsIssue.reasons(), ", ")}."
       }}
    end
  end

  defp reason(_kind, _value), do: {:ok, nil}

  # --- execute: post, then shape the answer -----------------------------------

  defp execute(request, ctx) do
    user_uuid = ctx |> Map.get(:actor, %{}) |> Map.get(:user_uuid)

    case post(request, user_uuid) do
      {:ok, doc} -> finish(:posted, doc, request, ctx)
      {:ok, :already_posted, doc} -> finish(:skipped, doc, request, ctx)
      {:error, reason} -> refuse(reason, request)
    end
  end

  defp post(%{kind: :receipt} = request, user_uuid),
    do: GoodsReceipts.create_and_post(attrs(request), user_uuid)

  defp post(%{kind: :inventory} = request, user_uuid),
    do: Inventories.create_and_post(attrs(request), user_uuid)

  defp post(%{kind: :issue} = request, user_uuid),
    do: GoodsIssues.create_and_post(attrs(request), user_uuid)

  defp attrs(request) do
    base = %{
      location_uuid: request.location_uuid,
      lines: Enum.map(request.lines, &line_attrs(request.kind, &1)),
      external_ref: request.external_ref,
      note: request.note
    }

    if request.kind == :issue, do: Map.put(base, :reason, request.reason), else: base
  end

  # What the Warehouse pages print for a line (name, SKU, unit) and the
  # catalogue it came from. Lines made in the admin carry them, so lines made
  # here must too, or the pages show nameless lines (`line["name"] || "—"`).
  defp identity(%{item: item}) do
    %{
      "name" => item.name,
      "sku" => item.sku,
      "unit" => item.unit,
      "catalogue_uuid" => item.catalogue_uuid
    }
  end

  defp line_attrs(:receipt, line) do
    base =
      Map.merge(identity(line), %{
        "item_uuid" => line.item.uuid,
        "received_quantity" => Quantity.to_param(line.quantity)
      })

    if line.unit_value,
      do: Map.put(base, "unit_value", Quantity.to_param(line.unit_value)),
      else: base
  end

  defp line_attrs(:inventory, line) do
    Map.merge(identity(line), %{
      "item_uuid" => line.item.uuid,
      "counted_quantity" => Quantity.to_param(line.quantity)
    })
  end

  defp line_attrs(:issue, line) do
    Map.merge(identity(line), %{
      "item_uuid" => line.item.uuid,
      "issued_quantity" => Quantity.to_param(line.quantity)
    })
  end

  defp finish(status, doc, request, ctx) do
    {doc, effects} = after_post(status, request, doc)
    if status == :posted, do: Audit.posted(request, doc, ctx)

    results = results(status, request, doc)

    body = %{
      "status" => Atom.to_string(status),
      "document" => document(request.kind, doc),
      "results" => results,
      "summary" => Enum.frequencies_by(results, & &1["action"])
    }

    reply(body, effects)
  end

  defp reply(body, []), do: {:ok, body}
  defp reply(body, effects), do: {:ok, body, effects}

  # Work that follows a posting and may add effects to the answer.
  #
  # A repeated reference that got past the early lookup of `run/3` (a retry
  # racing the first call) is answered by the posting layer: compare its
  # lines too.
  defp after_post(:skipped, request, doc) do
    requested = Enum.map(request.lines, &{&1.item.uuid, &1.quantity})

    wanted = %{
      location: request.location_uuid,
      catalogue: nil,
      reason: request.reason,
      order: request.order_uuid
    }

    effects =
      reference_effects(doc, request.kind, {:ok, requested}) ++
        basis_effects(doc, request.kind, wanted)

    {doc, effects}
  end

  # A shop-order basis is attached with `GoodsIssues.add_source_ref/3`, which
  # stores `%{"type" => "shop_order", "uuid" => id}` (the key is "type", never
  # "kind"). It is a second write: if it fails the document is already posted
  # and immutable, so the call still succeeds and carries an effect.
  defp after_post(:posted, %{kind: :issue, order_uuid: order_uuid}, doc)
       when is_binary(order_uuid) do
    case GoodsIssues.add_source_ref(doc, "shop_order", order_uuid) do
      {:ok, updated} ->
        {updated, []}

      {:error, reason} ->
        Logger.warning("[PhoenixKitWarehouse.API] could not link order: #{reason_kind(reason)}")

        {doc,
         [
           %{
             "code" => "source_ref_not_attached",
             "message" =>
               "The goods issue was posted, but linking it to the order failed. Link it from the admin UI."
           }
         ]}
    end
  end

  defp after_post(_status, _request, doc), do: {doc, []}

  defp document(kind, doc) do
    spec = Map.fetch!(@kinds, kind)

    %{
      "id" => doc.uuid,
      "type" => spec.type,
      "number" => doc.number,
      "external_ref" => doc.external_ref,
      "location_id" => doc.location_uuid,
      "posted_at" => iso(doc.posted_at)
    }
    |> put_reason(doc)
  end

  defp put_reason(document, %GoodsIssue{reason: reason}), do: Map.put(document, "reason", reason)
  defp put_reason(document, _doc), do: document

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp results(:skipped, request, _doc) do
    Enum.map(request.lines, &%{"ref" => &1.ref, "action" => "skipped", "id" => &1.item.uuid})
  end

  defp results(:posted, request, doc) do
    Enum.map(request.lines, fn line ->
      {from, to} = change(request.kind, line, doc)

      %{
        "ref" => line.ref,
        "action" => if(Decimal.eq?(from, to), do: "unchanged", else: "updated"),
        "id" => line.item.uuid,
        "from" => Quantity.format(from),
        "to" => Quantity.format(to)
      }
    end)
  end

  # Public only so that a test can feed a document whose `previous_quantity`
  # and `resulting_quantity` disagree, which is what a concurrent writer
  # produces.
  @doc false
  @spec line_change(:receipt | :inventory | :issue, map(), map()) :: {Decimal.t(), Decimal.t()}
  def line_change(kind, line, doc), do: change(kind, line, doc)

  # `{from, to}` of one line of a posted document, from its audited lines.
  defp change(:receipt, line, doc) do
    audited = audited_line(doc, line)
    from = StockLedger.to_decimal(audited["previous_quantity"])

    case audited["resulting_quantity"] do
      nil ->
        {from, Decimal.add(from, line.quantity)}

      resulting ->
        to = StockLedger.to_decimal(resulting)
        {Decimal.sub(to, line.quantity), to}
    end
  end

  # The stock rows were locked by the shortage check (`GoodsIssues.check_stock/3`)
  # before `previous_quantity` was read, so `from` is exact.
  defp change(:issue, line, doc) do
    audited = audited_line(doc, line)
    from = StockLedger.to_decimal(audited["previous_quantity"])
    {from, Decimal.sub(from, line.quantity)}
  end

  defp change(:inventory, line, doc) do
    # The prior quantity of an inventory line is read under a row lock inside
    # the posting transaction (`Inventories.locked_prior_stock/3`): exact.
    audited = audited_line(doc, line)
    {StockLedger.to_decimal(audited["previous_quantity"]), line.quantity}
  end

  defp audited_line(doc, line),
    do: Enum.find(doc.lines, %{}, &(&1["item_uuid"] == line.item.uuid))

  # --- a retry: the reference already names a posted document ------------------

  defp posted_by_reference(kind, input) do
    case Source.reference(kind, input) do
      {:ok, external_ref} when is_binary(external_ref) ->
        existing(Map.fetch!(@kinds, kind).schema, external_ref)

      _no_usable_reference ->
        nil
    end
  end

  # The posted, not deleted document with this reference: the posting layer's
  # own lookup, so there is one definition of "already posted". Outside a
  # transaction its advisory lock lasts one statement.
  defp existing(schema, external_ref) do
    {:ok, document} = PostingSupport.find_posted_by_external_ref(repo(), schema, external_ref)
    document
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp answer_retry(kind, input, doc) do
    {body, effects} = retry_body(kind, input, doc)
    reply(Map.put(body, "status", "skipped"), effects)
  end

  # The answer built from the stored document (its number, its lines in the
  # order they were posted), and what this request asks for, compared with it.
  defp retry_body(kind, input, doc) do
    results = retry_results(doc, input["lines"])

    body = %{
      "document" => document(kind, doc),
      "results" => results,
      "summary" => Enum.frequencies_by(results, & &1["action"])
    }

    effects =
      reference_effects(doc, kind, requested_lines(input)) ++
        basis_effects(doc, kind, requested_basis(kind, input))

    {body, effects}
  end

  defp retry_results(doc, raw_lines) do
    raw = if is_list(raw_lines), do: raw_lines, else: []

    doc.lines
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      item_uuid = line["item_uuid"]

      %{
        "ref" => echo_ref(Enum.at(raw, index), item_uuid),
        "action" => "skipped",
        "id" => item_uuid
      }
    end)
  end

  # The caller's own ref when it is the id of the stored line at that
  # position, otherwise the id form.
  defp echo_ref(%{"ref" => %{"id" => id} = ref}, item_uuid) when is_binary(id) do
    if Refs.cast_uuid(id) == {:ok, item_uuid}, do: ref, else: %{"id" => item_uuid}
  end

  defp echo_ref(_raw, item_uuid), do: %{"id" => item_uuid}

  # What this request asks for as `[{item_uuid, quantity}]`, or `:unknown`
  # when it can no longer be read (a product no longer resolves, a quantity
  # is wrong, the catalogue is closed).
  defp requested_lines(input) do
    catalogue_uuid =
      case Refs.catalogue_scope(input["catalogue_id"], :write) do
        {:ok, uuid} -> uuid
        {:error, _error} -> nil
      end

    case Lines.prepare(input["lines"], minimum: :zero, catalogue_uuid: catalogue_uuid) do
      {:ok, lines} -> {:ok, Enum.map(lines, &{&1.item.uuid, &1.quantity})}
      {:error, _errors} -> :unknown
    end
  end

  # The posting layer answers a repeated reference with the existing document
  # and compares nothing. A reference reused by another system, another key
  # or a changed body must not pass for a harmless retry: the answer says so
  # (stock did not move either way).
  defp reference_effects(doc, kind, {:ok, requested}) do
    if same_lines?(doc, kind, requested), do: [], else: [lines_differ_effect(doc)]
  end

  defp reference_effects(doc, _kind, :unknown), do: [lines_unverified_effect(doc)]

  defp same_lines?(doc, kind, requested) do
    key = quantity_key(kind)
    stored = Map.new(doc.lines, &{&1["item_uuid"], StockLedger.to_decimal(&1[key])})

    map_size(stored) == length(requested) and
      Enum.all?(requested, fn {item_uuid, quantity} ->
        case Map.fetch(stored, item_uuid) do
          {:ok, posted} -> Decimal.eq?(posted, quantity)
          :error -> false
        end
      end)
  end

  # What the request states besides its lines: an explicit `location_id`, an
  # explicit `reason`, a shop-order source (each `nil` when not stated). A
  # location left out is the default warehouse, which may have moved since:
  # it is not compared.
  defp requested_basis(kind, input) do
    %{
      location: explicit_location(input["location_id"]),
      catalogue: input["catalogue_id"],
      reason: if(kind == :issue, do: input["reason"]),
      order: if(kind == :issue, do: order_of(input["source"]))
    }
  end

  defp explicit_location(nil), do: nil

  defp explicit_location(id) when is_binary(id) do
    case Refs.cast_uuid(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp explicit_location(_other), do: :invalid

  defp order_of(%{"kind" => "shop_order", "id" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp order_of(_source), do: nil

  # The same warning for the rest of the basis: a reference reused for another
  # warehouse, catalogue, reason or order is not a retry either, and the stock
  # did not move.
  defp basis_effects(doc, kind, wanted) do
    differing =
      for {name, differs?} <- [
            {"location_id", location_differs?(doc, wanted.location)},
            {"catalogue_id", catalogue_differs?(doc, wanted.catalogue)},
            {"reason", reason_differs?(doc, kind, wanted.reason)}
          ],
          differs?,
          do: name

    List.wrap(basis_differs_effect(doc, differing)) ++ order_effects(doc, kind, wanted.order)
  end

  defp location_differs?(_doc, nil), do: false
  defp location_differs?(doc, location), do: location != doc.location_uuid

  defp catalogue_differs?(_doc, nil), do: false

  defp catalogue_differs?(doc, explicit) do
    stored = doc.lines |> Enum.map(& &1["catalogue_uuid"]) |> Enum.reject(&is_nil/1)

    case {stored, Refs.catalogue_scope(explicit, :read)} do
      {[], _scope} -> false
      {_stored, {:error, _error}} -> true
      {stored, {:ok, uuid}} -> uuid not in stored
    end
  end

  defp reason_differs?(%GoodsIssue{reason: posted}, :issue, reason) when is_binary(reason),
    do: reason != posted

  defp reason_differs?(_doc, _kind, _reason), do: false

  defp basis_differs_effect(_doc, []), do: nil

  defp basis_differs_effect(doc, differing) do
    %{
      "code" => "external_ref_basis_differs",
      "message" =>
        "This external_ref belongs to document ##{doc.number}, which was posted with a different " <>
          "#{Enum.join(differing, ", ")}. Nothing was posted now. " <>
          "If this is a new document, send a new external_ref."
    }
  end

  defp order_effects(%GoodsIssue{} = doc, :issue, order_uuid) when is_binary(order_uuid) do
    if Enum.any?(
         doc.source_refs || [],
         &(&1["type"] == "shop_order" and &1["uuid"] == order_uuid)
       ),
       do: [],
       else: [
         %{
           "code" => "source_ref_not_attached",
           "message" =>
             "This external_ref belongs to document ##{doc.number}, which is not linked to this order. " <>
               "Nothing was posted now. Link it from the admin UI."
         }
       ]
  end

  defp order_effects(_doc, _kind, _order_uuid), do: []

  defp quantity_key(:receipt), do: "received_quantity"
  defp quantity_key(:inventory), do: "counted_quantity"
  defp quantity_key(:issue), do: "issued_quantity"

  defp lines_differ_effect(doc) do
    %{
      "code" => "external_ref_lines_differ",
      "message" =>
        "This external_ref belongs to document ##{doc.number}, which was posted with different lines. " <>
          "Nothing was posted now. If these lines are a new document, send a new external_ref."
    }
  end

  defp lines_unverified_effect(doc) do
    %{
      "code" => "external_ref_lines_unverified",
      "message" =>
        "This external_ref belongs to document ##{doc.number}. The lines of this request could not be " <>
          "compared with it (a product no longer resolves, or a line is invalid). Nothing was posted now."
    }
  end

  # --- preview: what a real call would do, with no side effects ----------------

  # A repeated reference: the answer a real call gives, as a preview (reads only).
  defp preview_retry(kind, input, doc) do
    {body, effects} = retry_body(kind, input, doc)
    body = Map.put(body, "status", "would_skip")
    body = if effects == [], do: body, else: Map.put(body, "effects", effects)

    {:preview, body, fingerprint({kind, doc.uuid})}
  end

  # Reads the current stock; writes nothing (no draft, no stock row, no
  # Activity entry, no source ref).
  defp preview(request) do
    spec = Map.fetch!(@kinds, request.kind)
    current = current_quantities(request)

    case shortages(request, current) do
      [] ->
        results = preview_results(request, current)

        body = %{
          "status" => "would_post",
          "document" => preview_document(request, spec),
          "results" => results,
          "summary" => Enum.frequencies_by(results, & &1["action"])
        }

        {:preview, body,
         fingerprint({request.kind, request.location_uuid, line_state(request, current)})}

      short ->
        insufficient(request, short)
    end
  end

  defp current_quantities(request) do
    request.lines
    |> Enum.map(& &1.item.uuid)
    |> StockLedger.stock_for_items_at_location(request.location_uuid)
    |> Map.new(&{&1.item_uuid, &1.quantity})
  end

  defp from_of(current, line), do: Map.get(current, line.item.uuid, Decimal.new(0))

  defp shortages(%{kind: :issue} = request, current) do
    Enum.flat_map(request.lines, fn line ->
      available = from_of(current, line)

      if Decimal.lt?(available, line.quantity),
        do: [{line.item.uuid, line.quantity, available}],
        else: []
    end)
  end

  defp shortages(_request, _current), do: []

  defp preview_results(request, current) do
    Enum.map(request.lines, fn line ->
      from = from_of(current, line)
      to = project(request.kind, from, line.quantity)

      %{
        "ref" => line.ref,
        "action" => if(Decimal.eq?(from, to), do: "unchanged", else: "updated"),
        "id" => line.item.uuid,
        "from" => Quantity.format(from),
        "to" => Quantity.format(to)
      }
    end)
  end

  defp project(:receipt, from, quantity), do: Decimal.add(from, quantity)
  defp project(:issue, from, quantity), do: Decimal.sub(from, quantity)
  defp project(:inventory, _from, quantity), do: quantity

  defp preview_document(request, spec) do
    base = %{
      "id" => nil,
      "type" => spec.type,
      "number" => nil,
      "external_ref" => request.external_ref,
      "location_id" => request.location_uuid,
      "posted_at" => nil
    }

    if request.kind == :issue, do: Map.put(base, "reason", request.reason), else: base
  end

  defp line_state(request, current),
    do: Enum.map(request.lines, &{&1.item.uuid, Quantity.format(from_of(current, &1))})

  # A hash of the current values of what the operation touches: never
  # `updated_at`, so an unrelated touch of the row does not change it.
  defp fingerprint(material),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(material)) |> Base.encode16(case: :lower)

  # --- refusals from the posting layer ----------------------------------------

  defp refuse({:insufficient_stock, short}, request) when is_list(short) do
    insufficient(request, Enum.map(short, &{&1.item_uuid, &1.requested, &1.available}))
  end

  defp refuse({:insufficient_stock, item_uuid}, request) when is_binary(item_uuid) do
    requested =
      case Enum.find(request.lines, &(&1.item.uuid == item_uuid)) do
        nil -> Decimal.new(0)
        line -> line.quantity
      end

    available = StockLedger.get_quantity(item_uuid, request.location_uuid)
    insufficient(request, [{item_uuid, requested, available}])
  end

  defp refuse({:duplicate_lines, uuids}, request),
    do: refuse_lines("duplicate_line", "This product is on more than one line.", uuids, request)

  defp refuse({:invalid_quantity, uuids}, request),
    do: refuse_lines("validation_failed", "quantity is not valid.", uuids, request)

  defp refuse(reason, _request) when reason in [:no_lines, :invalid_lines] do
    refuse_request([
      %{path: "lines", code: "validation_failed", message: "lines are missing or malformed."}
    ])
  end

  defp refuse(%Ecto.Changeset{} = changeset, _request),
    do: refuse_request(changeset_errors(changeset))

  # Only the shape of the reason is logged: a reason may carry request values.
  defp refuse(reason, _request) do
    Logger.error("[PhoenixKitWarehouse.API] posting failed: #{reason_kind(reason)}")
    fail(:internal_error, "The document could not be posted.", %{posted: false})
  end

  defp reason_kind(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_kind(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: Atom.to_string(elem(reason, 0))

  defp reason_kind(_reason), do: "unexpected reason"

  # `short` is a list of `{item_uuid, requested, available}`. The answer lists
  # every short line with the caller's own ref.
  defp insufficient(request, short) do
    lines =
      Enum.map(short, fn {item_uuid, requested, available} ->
        line = Enum.find(request.lines, &(&1.item.uuid == item_uuid))

        %{
          product: item_uuid,
          ref: line && line.ref,
          sku: line && line.item.sku,
          requested: Quantity.format(requested),
          available: Quantity.format(available)
        }
      end)

    fail(
      :insufficient_stock,
      "Nothing was posted: #{length(lines)} line(s) exceed the stock on hand.",
      %{lines: lines, posted: false}
    )
  end

  defp refuse_lines(code, message, uuids, request) do
    errors =
      for line <- request.lines, line.item.uuid in uuids do
        %{path: "lines[#{line.index}]", code: code, message: message}
      end

    refuse_request(errors)
  end

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      messages
      |> List.wrap()
      |> Enum.map(&%{path: to_string(field), code: "validation_failed", message: to_string(&1)})
    end)
  end
end
