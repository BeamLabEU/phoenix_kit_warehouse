defmodule PhoenixKitWarehouse.SourceKinds do
  @moduledoc """
  Generic registry/dispatch for the `source_refs` decoupling contract.

  `phoenix_kit_warehouse` documents (Internal Orders, Goods Issues) link back
  to arbitrary host-owned "source" records — a sub-order, a top-level order,
  or anything else a consuming app wants to link — via a `source_refs` JSONB
  column shaped `[%{"type" => "sub_order", "uuid" => "..."}, ...]`. This
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

  A PhoenixKit module can also declare kinds itself, so a host need not (and
  cannot safely, since `config` replaces the list) patch the host list: any
  module in `PhoenixKit.ModuleRegistry.all_modules/0` that exports
  `warehouse_source_kinds/0` returning a list of the same maps contributes
  them. `list_kinds/0` merges both sources, deduplicated by `kind`; the host
  list comes first and wins on a conflict, then modules in registry order.

  With no `source_kinds` configured and no module declaring any, every
  function in this module degrades gracefully: `search_candidates/1` returns
  `[]`, `resolve/2` returns `:error` (callers show a plain UUID), and
  `build_lines/3` returns `{:error, :unsupported_kind}`. This is what makes
  the package usable standalone, with no host "order" concept at all.

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

  @doc """
  All registered kinds: the host app's `:source_kinds` config (in config
  order) followed by the kinds declared by registered PhoenixKit modules
  exporting `warehouse_source_kinds/0`. Deduplicated by `kind` — the host's
  entry wins over a module's, and the first module wins over a later one.

  A module whose callback raises contributes nothing, and entries of its
  list that are not kind maps with a string `:kind` are dropped; both are
  logged (once per module and problem, since this runs at render rate) and
  neither breaks the list. A bare kind map is accepted in place of
  a one-element list.

  `warehouse_source_kinds/0` runs on every call (this function is reached
  once per rendered ref), so it must be cheap and pure: return a literal
  list, do not query.
  """
  @spec list_kinds() :: [kind_config()]
  def list_kinds do
    host_kinds = Application.get_env(:phoenix_kit_warehouse, :source_kinds, [])

    Enum.uniq_by(host_kinds ++ module_declared_kinds(), & &1.kind)
  end

  defp module_declared_kinds do
    PhoenixKit.ModuleRegistry.all_modules()
    |> Enum.filter(&declares_kinds?/1)
    |> Enum.flat_map(&declared_by/1)
  end

  defp declares_kinds?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :warehouse_source_kinds, 0)
  end

  defp declared_by(module) do
    {kinds, dropped} =
      module.warehouse_source_kinds()
      |> List.wrap()
      |> Enum.split_with(&match?(%{kind: kind} when is_binary(kind), &1))

    if dropped != [] do
      warn_once(
        {module, :dropped},
        "PhoenixKitWarehouse.SourceKinds: #{inspect(module)}.warehouse_source_kinds/0 " <>
          "returned #{length(dropped)} entr#{if length(dropped) == 1, do: "y", else: "ies"} " <>
          "that are not kind maps with a string :kind; ignored"
      )
    end

    kinds
  rescue
    error ->
      warn_once(
        {module, :raised},
        "PhoenixKitWarehouse.SourceKinds: #{inspect(module)}.warehouse_source_kinds/0 raised: " <>
          Exception.message(error)
      )

      []
  end

  # `list_kinds/0` runs at render rate, so a module that stays broken is
  # reported once per VM, not on every call.
  defp warn_once(key, message) do
    flag = {__MODULE__, :warned, key}

    unless :persistent_term.get(flag, false) do
      :persistent_term.put(flag, true)
      Logger.warning(message)
    end

    :ok
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
  Resolves an existing `%{"type" => kind, "uuid" => uuid}` source ref to a
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
