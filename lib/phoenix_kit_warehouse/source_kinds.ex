defmodule PhoenixKitWarehouse.SourceKinds do
  @moduledoc """
  Generic registry/dispatch for the `source_refs` decoupling contract.

  `phoenix_kit_warehouse` documents (Internal Orders, Goods Issues) link back
  to arbitrary host-owned "source" records — a sub-order, a top-level order,
  or anything else a consuming app wants to link — via a `source_refs` JSONB
  column shaped `[%{"kind" => "sub_order", "uuid" => "..."}, ...]`. This
  module never queries a host table directly; instead the host registers,
  per kind, three callbacks in its own config:

      config :phoenix_kit_warehouse,
        source_kinds: [
          %{
            kind: "sub_order",
            label: "Sub-order",
            search: {MyApp.Warehouse.Integration, :search_sub_orders, []},
            resolve: {MyApp.Warehouse.Integration, :resolve_sub_order, []},
            build_lines: {MyApp.Warehouse.Integration, :build_sub_order_lines, []}
          }
        ]

  With no `source_kinds` configured at all, every function in this module
  degrades gracefully: `search_candidates/1` returns `[]`, `resolve/2`
  returns `:error` (callers show a plain UUID), and `build_lines/3` returns
  `{:error, :unsupported_kind}`. This is what makes the package usable
  standalone, with no host "order" concept at all.

  `build_lines` is optional per kind — a kind can be searchable/resolvable
  (linkable, shows up in pickers and renders as a link) without being
  importable (lines cannot be built from it), by simply omitting the key.
  """

  require Logger

  @typedoc "An `{module, function, extra_args}` tuple dispatched via `apply(m, f, extra_args ++ dynamic_args)`."
  @type mf_args :: {module(), atom(), list()}

  @type kind_config :: %{
          required(:kind) => String.t(),
          required(:label) => String.t(),
          required(:search) => mf_args(),
          required(:resolve) => mf_args(),
          optional(:build_lines) => mf_args()
        }

  @doc "All kinds registered by the host app, in config order."
  @spec list_kinds() :: [kind_config()]
  def list_kinds do
    Application.get_env(:phoenix_kit_warehouse, :source_kinds, [])
  end

  @doc """
  Searches every registered kind for `query` and returns the merged
  candidate list, each tagged with its `kind` and `label` (as
  `label_prefix`) so a picker can group them. A kind whose `search`
  callback raises is skipped (logged), not fatal to the other kinds.
  """
  @spec search_candidates(String.t()) :: [
          %{
            kind: String.t(),
            label_prefix: String.t(),
            uuid: String.t(),
            label: String.t(),
            extra: term()
          }
        ]
  def search_candidates(query) when is_binary(query) do
    list_kinds()
    |> Enum.flat_map(&search_for_kind(&1, query))
  end

  defp search_for_kind(%{kind: kind, label: kind_label, search: {m, f, a}}, query) do
    m
    |> apply(f, a ++ [query])
    |> List.wrap()
    |> Enum.map(fn candidate ->
      %{
        kind: kind,
        label_prefix: kind_label,
        uuid: candidate.uuid,
        label: candidate.label,
        extra: Map.get(candidate, :extra)
      }
    end)
  rescue
    error ->
      Logger.warning(
        "PhoenixKitWarehouse.SourceKinds: search for kind #{kind} raised: #{Exception.message(error)}"
      )

      []
  end

  @doc """
  Resolves an existing `%{"kind" => kind, "uuid" => uuid}` source ref to a
  `%{label:, path:}` map for rendering a link. Returns `:error` if the kind
  isn't registered, the callback doesn't return the expected shape, or the
  callback itself raises — callers fall back to showing the plain UUID.
  """
  @spec resolve(String.t(), String.t()) :: %{label: String.t(), path: String.t()} | :error
  def resolve(kind, uuid) when is_binary(kind) and is_binary(uuid) do
    case find_kind(kind) do
      %{resolve: {m, f, a}} ->
        case apply(m, f, a ++ [uuid]) do
          %{label: _, path: _} = result -> result
          _ -> :error
        end

      nil ->
        :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Builds line-item data for a chosen import candidate — used when a draft
  Internal Order imports lines "from" a picked source. Returns
  `{:error, :unsupported_kind}` when the kind isn't registered or doesn't
  declare a `build_lines` callback.
  """
  @spec build_lines(String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | :error | {:error, :unsupported_kind}
  def build_lines(kind, uuid, actor_uuid)
      when is_binary(kind) and is_binary(uuid) and is_binary(actor_uuid) do
    case find_kind(kind) do
      %{build_lines: {m, f, a}} ->
        apply(m, f, a ++ [uuid, actor_uuid])

      %{} ->
        {:error, :unsupported_kind}

      nil ->
        {:error, :unsupported_kind}
    end
  rescue
    _ -> :error
  end

  defp find_kind(kind), do: Enum.find(list_kinds(), &(&1.kind == kind))
end
