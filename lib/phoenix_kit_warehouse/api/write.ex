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
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.PostingSupport
  alias PhoenixKitWarehouse.StockLedger

  @max_note 1000

  @kinds %{
    receipt: %{
      type: "goods_receipt",
      schema: GoodsReceipt,
      minimum: :positive,
      unit_value: true
    }
  }

  @type result ::
          {:ok, map()}
          | {:ok, map(), [map()]}
          | {:error, atom(), String.t(), map()}

  @doc "`warehouse.receive_stock`: a goods receipt with many lines."
  @spec receive_stock(map(), map()) :: result()
  def receive_stock(input, ctx), do: run(:receipt, input, ctx)

  defp run(kind, input, ctx) do
    case posted_by_reference(kind, input) do
      nil -> run_new(kind, input, ctx)
      doc -> answer_retry(kind, input, doc)
    end
  end

  defp run_new(kind, input, ctx) do
    case prepare(kind, input) do
      {:ok, request} -> execute(request, ctx)
      {:error, errors} -> refuse_request(errors)
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

  defp attrs(request) do
    %{
      location_uuid: request.location_uuid,
      lines: Enum.map(request.lines, &line_attrs(request.kind, &1)),
      external_ref: request.external_ref,
      note: request.note
    }
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
    {doc, reference_effects(doc, request.kind, {:ok, requested})}
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
  end

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

    {body, reference_effects(doc, kind, requested_lines(input))}
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

  # --- refusals from the posting layer ----------------------------------------

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
