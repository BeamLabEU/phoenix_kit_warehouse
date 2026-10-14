defmodule PhoenixKitWarehouse.API.Source do
  @moduledoc """
  The basis of a warehouse document: its `external_ref` (the document's
  number in an outside system) and, for a goods issue, its `source`.

  `external_ref` is the idempotency handle of the stock tools: the posting
  layer answers a repeat with the existing document. A reference that is
  blank would be turned into "no reference" by the posting layer and switch
  the protection off silently, so it is refused here instead.
  """

  alias PhoenixKitWarehouse.GoodsReceipt

  @type error :: %{path: String.t(), code: String.t(), message: String.t()}

  @doc """
  The basis of a request of `kind` (`:receipt`, `:inventory` or `:issue`).
  Receipts and inventories read the `"external_ref"` input.
  """
  @spec basis(:receipt | :inventory | :issue, map()) ::
          {:ok, %{external_ref: String.t() | nil, order_uuid: String.t() | nil}}
          | {:error, [error()]}
  def basis(_kind, input) do
    case clean_external_ref(input["external_ref"]) do
      {:ok, external_ref} -> {:ok, %{external_ref: external_ref, order_uuid: nil}}
      {:error, message} -> {:error, [error("external_ref", message)]}
    end
  end

  @doc """
  The `external_ref` a request carries, read with no database check: the
  `"external_ref"` input of a receipt or a stocktake, the `ref` of an
  `external` source of an issue. `{:ok, nil}` when there is none. The write
  tools look for an already posted document with it before anything else
  (a retry, `Write.run/3`).
  """
  @spec reference(:receipt | :inventory | :issue, map()) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  def reference(:issue, %{"source" => %{"kind" => "external", "ref" => ref}}),
    do: clean_external_ref(ref)

  def reference(:issue, _input), do: {:ok, nil}
  def reference(_kind, input), do: clean_external_ref(input["external_ref"])

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

  defp max_ref, do: GoodsReceipt.v2_column_widths().external_ref

  defp error(path, message), do: %{path: path, code: "validation_failed", message: message}
end
