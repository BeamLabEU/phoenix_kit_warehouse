defmodule PhoenixKitWarehouse.API.Source do
  @moduledoc """
  The basis of a warehouse document: its `external_ref` (the document's
  number in an outside system) and, for a goods issue, its `source`.

  `external_ref` is the idempotency handle of the stock tools: the posting
  layer answers a repeat with the existing document. A reference that is
  blank would be turned into "no reference" by the posting layer and switch
  the protection off silently, so it is refused here instead.
  """

  alias PhoenixKitWarehouse.API.Refs
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.SourceKinds

  # The kind the E-commerce module registers for orders.
  @order_kind "shop_order"

  @type error :: %{path: String.t(), code: String.t(), message: String.t()}

  @doc """
  The basis of a request of `kind` (`:receipt`, `:inventory` or `:issue`).
  Receipts and inventories read the `"external_ref"` input.

  A goods issue reads its `"source"`: `{"kind": "external", "ref": ...}` is
  the document's external reference, `{"kind": "shop_order", "id": ...}` links
  the issue to a shop order (checked here, linked by the posting itself). Beside
  a shop order, or with no source, the issue may also carry an
  `"external_ref"` of its own; beside an external source it may not, because
  the source's `ref` is already that reference.
  """
  @spec basis(:receipt | :inventory | :issue, map()) ::
          {:ok, %{external_ref: String.t() | nil, order_uuid: String.t() | nil}}
          | {:error, [error()]}
  def basis(:issue, input) do
    merge_issue_basis(from_source(input["source"]), clean_external_ref(input["external_ref"]))
  end

  def basis(_kind, input) do
    case clean_external_ref(input["external_ref"]) do
      {:ok, external_ref} -> {:ok, %{external_ref: external_ref, order_uuid: nil}}
      {:error, message} -> {:error, [error("external_ref", message)]}
    end
  end

  @doc """
  The `external_ref` a request carries, read with no database check: the
  `"external_ref"` input of a receipt or a stocktake, the `ref` of an
  `external` source of an issue or the `"external_ref"` input of an issue
  with a shop order or no source. `{:ok, nil}` when there is none. The write
  tools look for an already posted document with it before anything else
  (a retry, `Write.run/3`).
  """
  @spec reference(:receipt | :inventory | :issue, map()) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  def reference(:issue, input) do
    case {input["source"], input["external_ref"]} do
      {%{"kind" => "external", "ref" => ref} = source, nil} when map_size(source) == 2 ->
        clean_external_ref(ref)

      {nil, ref} ->
        clean_external_ref(ref)

      {%{"kind" => @order_kind, "id" => id} = source, ref}
      when map_size(source) == 2 and is_binary(id) ->
        order_reference(id, ref)

      # Both given, or a source of no known shape: not a retry the early
      # lookup can answer; the full check refuses the request.
      _other ->
        {:ok, nil}
    end
  end

  def reference(_kind, input), do: clean_external_ref(input["external_ref"])

  defp order_reference(id, ref) do
    case Refs.cast_uuid(id) do
      {:ok, _uuid} -> clean_external_ref(ref)
      :error -> {:ok, nil}
    end
  end

  @doc """
  Cleans a reference: `nil` stays `nil`; a string is trimmed and must then be
  1 to 255 codepoints (the width of the column and of the changesets) without
  control characters.
  """
  @spec clean_external_ref(term()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def clean_external_ref(nil), do: {:ok, nil}

  def clean_external_ref(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, "must not be blank."}

      length(String.codepoints(trimmed)) > max_ref() ->
        {:error, "must be at most #{max_ref()} characters."}

      String.match?(trimmed, ~r/[\x00-\x1f\x7f]/) ->
        {:error, "must not contain control characters."}

      true ->
        {:ok, trimmed}
    end
  end

  def clean_external_ref(_other), do: {:error, "must be a string."}

  # --- the `source` of a goods issue ------------------------------------------

  defp merge_issue_basis({:ok, basis}, {:ok, nil}), do: {:ok, basis}

  defp merge_issue_basis({:ok, %{external_ref: nil} = basis}, {:ok, external_ref}),
    do: {:ok, %{basis | external_ref: external_ref}}

  defp merge_issue_basis({:ok, _basis}, {:ok, _external_ref}) do
    {:error,
     [
       error(
         "external_ref",
         "must not be given with an external source: the source's ref is the external reference."
       )
     ]}
  end

  defp merge_issue_basis(source, external_ref) do
    {:error, source_errors(source) ++ external_ref_errors(external_ref)}
  end

  defp source_errors({:error, errors}), do: errors
  defp source_errors({:ok, _basis}), do: []

  defp external_ref_errors({:error, message}), do: [error("external_ref", message)]
  defp external_ref_errors({:ok, _external_ref}), do: []

  defp from_source(nil), do: {:ok, %{external_ref: nil, order_uuid: nil}}

  defp from_source(%{"kind" => "external"} = source) do
    case {Map.keys(source) -- ["kind", "ref"], Map.get(source, "ref")} do
      {[], ref} when is_binary(ref) ->
        case clean_external_ref(ref) do
          {:ok, clean} -> {:ok, %{external_ref: clean, order_uuid: nil}}
          {:error, message} -> {:error, [error("source.ref", message)]}
        end

      _other ->
        {:error,
         [
           error(
             "source",
             ~s(An external source is {"kind": "external", "ref": "<document number>"}.)
           )
         ]}
    end
  end

  defp from_source(%{"kind" => @order_kind} = source) do
    case {Map.keys(source) -- ["kind", "id"], Map.get(source, "id")} do
      {[], id} when is_binary(id) ->
        shop_order(id)

      _other ->
        {:error,
         [
           error(
             "source",
             ~s(A shop order source is {"kind": "shop_order", "id": "<order uuid>"}.)
           )
         ]}
    end
  end

  defp from_source(_other),
    do: {:error, [error("source", "kind must be external or #{@order_kind}.")]}

  defp shop_order(id) do
    case Refs.cast_uuid(id) do
      {:ok, uuid} -> check_order(uuid)
      :error -> {:error, [error("source.id", "must be an order UUID.")]}
    end
  end

  defp check_order(uuid) do
    cond do
      not Enum.any?(SourceKinds.list_kinds(), &(&1.kind == @order_kind)) ->
        {:error,
         [
           error(
             "source",
             "The #{@order_kind} source needs the E-commerce module, which registers that kind with the warehouse."
           )
         ]}

      not order_kind_enabled?() ->
        {:error,
         [
           error(
             "source",
             "The #{@order_kind} source needs the E-commerce module, which is installed but disabled. Enable it in Modules."
           )
         ]}

      SourceKinds.resolve(@order_kind, uuid) == :error ->
        {:error, [error("source.id", "No storefront order with this id.")]}

      true ->
        {:ok, %{external_ref: nil, order_uuid: uuid}}
    end
  end

  # `SourceKinds.list_kinds/0` collects the kinds of every REGISTERED module,
  # enabled or not (`source_kinds.ex:77-81`), so an installed but disabled
  # E-commerce still contributes `shop_order`. The kind counts as available
  # when the host configures it itself or an enabled module declares it
  # (`ModuleRegistry.enabled_modules/0` is core's own definition of enabled).
  defp order_kind_enabled? do
    host_kind?() or
      Enum.any?(PhoenixKit.ModuleRegistry.enabled_modules(), &declares_order_kind?/1)
  end

  defp host_kind? do
    :phoenix_kit_warehouse
    |> Application.get_env(:source_kinds, [])
    |> Enum.any?(&match?(%{kind: @order_kind}, &1))
  end

  defp declares_order_kind?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :warehouse_source_kinds, 0) and
      module.warehouse_source_kinds()
      |> List.wrap()
      |> Enum.any?(&match?(%{kind: @order_kind}, &1))
  rescue
    _error -> false
  end

  defp max_ref, do: GoodsReceipt.v2_column_widths().external_ref

  defp error(path, message), do: %{path: path, code: "validation_failed", message: message}
end
