defmodule PhoenixKitWarehouse.API.Refs do
  @moduledoc """
  Product refs of the warehouse API tools, and the catalogue they resolve in.

  A ref is an object with **exactly one** of `"id"` (a catalogue item UUID),
  `"sku"` or `"external_id"`. Every ref resolves to a **live** catalogue item
  (not trashed, and in a catalogue that is not deleted) or to a row error:
  stock rows carry no foreign key to the catalogue, so an unchecked UUID would
  create a phantom row.

    * `id` refs are resolved here with `Catalogue.list_items_by_uuids/2`.
    * `sku` and `external_id` refs go to `PhoenixKitCatalogue.API.resolve_refs/2`
      (which answers one `{ref, result}` tuple per ref) when the installed
      catalogue has it; otherwise they answer a `validation_failed` row error
      saying so. The resolver judges the item alone, not its catalogue, so
      whatever it says, the item it names is read again here: a trashed item
      or a closed catalogue is caught by this module.

  `catalogue_scope/2` is the rule for the `catalogue_id` input: refs resolve
  inside ONE catalogue, and the input is required when the install has more
  than one active catalogue. The rule lives in the catalogue
  (`PhoenixKitCatalogue.API.resolve_catalogue/2`); this module delegates to it
  and carries the same rule only as a fallback for a catalogue release that
  lacks it.

  A row error is `%{code: String.t(), message: String.t()}` plus
  `candidates: [uuid]` for `ambiguous_ref`. The codes are the row-level codes
  of the API: `not_found`, `ambiguous_ref`, `validation_failed`.
  """

  alias PhoenixKitCatalogue.Catalogue

  # `PhoenixKitCatalogue.API` is absent from older catalogue releases; it is
  # only reached behind `resolver_function?/2` (the pattern of `comments.ex`
  # for `PhoenixKitComments`).
  @compile {:no_warn_undefined, PhoenixKitCatalogue.API}

  @resolver PhoenixKitCatalogue.API
  @max_text 255

  @type resolved :: %{
          uuid: String.t(),
          sku: String.t() | nil,
          name: String.t() | nil,
          unit: String.t() | nil,
          catalogue_uuid: String.t() | nil
        }
  @type row_error :: %{
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(:candidates) => [String.t()]
        }
  @type scope_error :: %{
          required(:path) => String.t(),
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(:allowed) => [String.t()]
        }

  @doc """
  Resolves `refs` (a list of anything the caller sent). The result has the
  same length and order as the input.

  Options: `:catalogue_uuid` - resolve within this catalogue only (`nil` =
  any), as the tool's `catalogue_id` input does; `:write` - the refs are for a
  stock change, so an item of an archived catalogue is refused too (a read
  accepts it; a deleted catalogue is refused either way).
  """
  @spec resolve([term()], keyword()) :: [{:ok, resolved()} | {:error, row_error()}]
  def resolve(refs, opts \\ []) when is_list(refs) do
    scope = %{
      catalogue_uuid: Keyword.get(opts, :catalogue_uuid),
      write?: Keyword.get(opts, :write, false)
    }

    parsed = Enum.map(refs, &parse/1)

    by_id =
      parsed
      |> Enum.flat_map(fn
        {:ok, {:id, uuid}} -> [uuid]
        _other -> []
      end)
      |> live_items()

    external = resolve_external(parsed, scope.catalogue_uuid)

    # Whatever the resolver says, the item is read again: a trashed item is
    # not a product we may touch.
    live_external =
      external
      |> Map.values()
      |> Enum.flat_map(fn
        {:ok, uuid} -> [uuid]
        {:error, _error} -> []
      end)
      |> live_items()

    parsed
    |> Enum.with_index()
    |> Enum.map(fn
      {{:error, _error} = error, _index} ->
        error

      {{:ok, {:id, uuid}}, _index} ->
        by_id |> Map.get(uuid) |> usable(scope)

      {{:ok, {_kind, _value}}, index} ->
        case Map.get(external, index, {:error, generic_error()}) do
          {:ok, uuid} -> live_external |> Map.get(uuid) |> usable(scope)
          {:error, _error} = error -> error
        end
    end)
  end

  @doc """
  The catalogue a tool works in, from its optional `catalogue_id` input.
  `mode` is `:read` or `:write`.

    * `nil` is the only active standard catalogue; with several active
      catalogues the input is required and the answer says so, with none the
      answer says that.
    * An id must name a catalogue that is not deleted (and not a smart one).
      An archived catalogue can be read, not written.

  Answers `{:ok, catalogue_uuid}` (always a UUID) or a `validation_failed`
  error at `catalogue_id`. The refusal for a missing `catalogue_id` carries
  the UUIDs to choose from as `allowed`.
  """
  @spec catalogue_scope(term(), :read | :write) :: {:ok, String.t()} | {:error, scope_error()}
  def catalogue_scope(term, mode \\ :read) when mode in [:read, :write] do
    if resolver_function?(:resolve_catalogue, 2),
      do: delegated_scope(term, mode),
      else: fallback_scope(term, mode)
  end

  # The one place that knows the shape of the catalogue's answer:
  # {:ok, catalogue} | {:error, code, message, context}. Every refusal is a
  # validation_failed at catalogue_id. The resolver reads any 16-byte string
  # as a raw UUID, so only `nil` and the text form of a UUID reach it.
  defp delegated_scope(nil, mode), do: ask_for_catalogue(nil, mode)

  defp delegated_scope(id, mode) when is_binary(id) do
    case cast_uuid(id) do
      {:ok, uuid} -> ask_for_catalogue(uuid, mode)
      :error -> {:error, scope_error("No catalogue with this id.")}
    end
  end

  defp delegated_scope(_other, _mode),
    do: {:error, scope_error("catalogue_id must be a catalogue UUID.")}

  defp ask_for_catalogue(term, mode) do
    resolver = @resolver

    case resolver.resolve_catalogue(term, writable: mode == :write) do
      {:ok, %{uuid: uuid}} ->
        {:ok, uuid}

      {:error, _code, message, context} when is_binary(message) ->
        {:error, scope_error(message, allowed(context))}
    end
  end

  # The values the resolver offers for the field (`errors[0].allowed`).
  defp allowed(%{errors: [%{allowed: [_ | _] = allowed} | _]}), do: allowed
  defp allowed(_context), do: nil

  # The same rule, for a catalogue release without `resolve_catalogue/2`.
  defp fallback_scope(nil, _mode) do
    case Catalogue.list_catalogues(status: "active", kind: :standard) do
      [only] ->
        {:ok, only.uuid}

      [] ->
        {:error, scope_error("There is no active catalogue.")}

      many ->
        {:error,
         scope_error(
           "catalogue_id is required: this install has #{length(many)} active catalogues.",
           Enum.map(many, & &1.uuid)
         )}
    end
  end

  defp fallback_scope(id, mode) when is_binary(id) do
    with {:ok, uuid} <- cast_uuid(id),
         %{} = catalogue <- Catalogue.get_catalogue(uuid) do
      fallback_check(catalogue, mode)
    else
      _unknown -> {:error, scope_error("No catalogue with this id.")}
    end
  end

  defp fallback_scope(_other, _mode),
    do: {:error, scope_error("catalogue_id must be a catalogue UUID.")}

  defp fallback_check(%{status: "deleted"}, _mode),
    do: {:error, scope_error("No catalogue with this id.")}

  defp fallback_check(%{kind: kind}, _mode) when kind != "standard",
    do: {:error, scope_error("Smart catalogues are not available through the API.")}

  defp fallback_check(%{status: status}, :write) when status != "active",
    do: {:error, scope_error("The catalogue is archived: it can be read but not changed.")}

  defp fallback_check(%{uuid: uuid}, _mode), do: {:ok, uuid}

  defp scope_error(message, allowed \\ nil) do
    error = %{path: "catalogue_id", code: "validation_failed", message: message}
    if allowed, do: Map.put(error, :allowed, allowed), else: error
  end

  @doc false
  # `Ecto.UUID.cast/1` takes any 16-byte binary as a raw UUID, so a 16-character
  # string would turn into an unrelated UUID. Only the 36-character text form
  # (any letter case) is an id.
  @spec cast_uuid(term()) :: {:ok, String.t()} | :error
  def cast_uuid(id) when is_binary(id) and byte_size(id) == 36, do: Ecto.UUID.cast(id)
  def cast_uuid(_other), do: :error

  @doc "A row error as JSON-ready data: `code`, `message`, and `candidates` when present."
  @spec error_json(row_error()) :: map()
  def error_json(%{code: code, message: message} = error) do
    base = %{"code" => code, "message" => message}

    case Map.get(error, :candidates) do
      nil -> base
      candidates -> Map.put(base, "candidates", candidates)
    end
  end

  # --- parsing --------------------------------------------------------------

  defp parse(%{} = ref) when not is_struct(ref) do
    case Map.to_list(ref) do
      [{"id", id}] when is_binary(id) ->
        case cast_uuid(id) do
          {:ok, uuid} -> {:ok, {:id, uuid}}
          :error -> invalid("id must be a UUID.")
        end

      [{"sku", value}] ->
        text(:sku, value)

      [{"external_id", value}] ->
        text(:external_id, value)

      _other ->
        invalid("A ref is an object with exactly one of id, sku or external_id.")
    end
  end

  defp parse(_other),
    do: invalid("A ref is an object with exactly one of id, sku or external_id.")

  defp text(kind, value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.length(trimmed) <= @max_text do
      {:ok, {kind, trimmed}}
    else
      invalid("#{kind} must be 1 to #{@max_text} characters.")
    end
  end

  defp text(kind, _value), do: invalid("#{kind} must be a string.")

  defp invalid(message), do: {:error, %{code: "validation_failed", message: message}}

  # --- items ----------------------------------------------------------------

  # `list_items_by_uuids/2` leaves out trashed items and preloads `:catalogue`.
  defp live_items([]), do: %{}

  defp live_items(uuids) do
    uuids
    |> Enum.uniq()
    |> Catalogue.list_items_by_uuids()
    |> Map.new(&{&1.uuid, &1})
  end

  defp usable(nil, _scope), do: {:error, not_found()}

  defp usable(item, %{catalogue_uuid: scope_uuid, write?: write?}) do
    cond do
      scope_uuid != nil and item.catalogue_uuid != scope_uuid ->
        {:error, not_found()}

      not catalogue_usable?(Map.get(item, :catalogue), write?) ->
        {:error, catalogue_closed()}

      true ->
        {:ok, summary(item)}
    end
  end

  # A deleted catalogue's items are not products; an archived catalogue can be
  # read but not written (the rule of `resolve_catalogue/2`).
  defp catalogue_usable?(%{status: "deleted"}, _write?), do: false
  defp catalogue_usable?(%{status: status}, true), do: status == "active"
  defp catalogue_usable?(_catalogue, _write?), do: true

  # What the admin pages print for a line (name, SKU, unit) travels with the
  # item, so a document made here looks like one made in the UI.
  defp summary(item) do
    %{
      uuid: item.uuid,
      sku: Map.get(item, :sku),
      name: Map.get(item, :name),
      unit: Map.get(item, :unit),
      catalogue_uuid: Map.get(item, :catalogue_uuid)
    }
  end

  defp not_found, do: %{code: "not_found", message: "No product with this ref."}

  defp catalogue_closed,
    do: %{code: "not_found", message: "The product's catalogue is deleted or archived."}

  defp generic_error,
    do: %{code: "validation_failed", message: "The catalogue could not resolve this ref."}

  # --- sku / external_id refs -----------------------------------------------

  # Answers `%{index => {:ok, item_uuid} | {:error, row_error}}`.
  defp resolve_external(parsed, catalogue_uuid) do
    entries =
      parsed
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:ok, {kind, value}}, index} when kind in [:sku, :external_id] ->
          [{index, %{Atom.to_string(kind) => value}}]

        _other ->
          []
      end)

    cond do
      entries == [] -> %{}
      resolver_function?(:resolve_refs, 2) -> ask_resolver(entries, catalogue_uuid)
      true -> Map.new(entries, fn {index, _ref} -> {index, {:error, missing_resolver()}} end)
    end
  end

  defp resolver_function?(name, arity),
    do: Code.ensure_loaded?(@resolver) and function_exported?(@resolver, name, arity)

  defp missing_resolver do
    %{
      code: "validation_failed",
      message:
        "sku and external_id refs need a phoenix_kit_catalogue release with the shop API support; use id."
    }
  end

  # The one place that knows the shape of the catalogue's resolver: one
  # `{ref, result}` tuple per input ref, in input order.
  defp ask_resolver(entries, catalogue_uuid) do
    resolver = @resolver
    refs = Enum.map(entries, &elem(&1, 1))
    results = resolver.resolve_refs(refs, kind: :item, catalogue_uuid: catalogue_uuid)

    entries
    |> Enum.zip(results)
    |> Map.new(fn {{index, _ref}, {_echoed_ref, result}} ->
      {index, normalize_external(result)}
    end)
  end

  @doc false
  # Public for its own test: every answer of the catalogue resolver, and a
  # catch-all so a shape the resolver adds later is a row error, not a crash.
  @spec normalize_external(term()) :: {:ok, String.t()} | {:error, row_error()}
  def normalize_external({:ok, %{uuid: uuid}}), do: {:ok, uuid}
  def normalize_external({:error, :not_found}), do: {:error, not_found()}

  def normalize_external({:error, :invalid_ref}),
    do: invalid("A ref is an object with exactly one of id, sku or external_id.")

  def normalize_external({:error, {:ambiguous_ref, candidates}}) when is_list(candidates) do
    {:error,
     %{
       code: "ambiguous_ref",
       message: "More than one product matches this ref; use id.",
       candidates: candidates
     }}
  end

  def normalize_external(_other), do: {:error, generic_error()}
end
