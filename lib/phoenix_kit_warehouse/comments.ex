defmodule PhoenixKitWarehouse.Comments do
  @moduledoc """
  Thin isolation layer over `PhoenixKitComments` for every warehouse document
  kind.

  Consolidates what were 5 near-byte-identical `*_comments.ex` wrapper
  modules in Andi (`goods_issue_comments.ex`, `goods_receipt_comments.ex`,
  `internal_order_comments.ex`, `supplier_order_comments.ex`,
  `inventory_comments.ex`) into one module parameterized by a `kind` atom.
  Every function returns a neutral value rather than raising when comments are
  unavailable, so callers never special-case it.

  ## What "unavailable" does and does not cover

  `phoenix_kit_comments` is a hard dependency (`mix.exs`, not `optional:`), so
  in practice "unavailable" means **installed but disabled** — the
  `PhoenixKitComments.enabled?/0` half of `available?/0`. The
  `Code.ensure_loaded?/1` half, like the `@compile {:no_warn_undefined, ...}`
  below, is always-true residue from treating the package as optional; both are
  harmless and left in place, but neither is what makes this module safe.

  It does **not** cover version skew. `available?/0` answers "is the module
  there and switched on", not "is it new enough": against comments 0.2.6 or
  0.2.7 the module is present and `enabled?/0` exists, so `available?/0`
  returns `true` and `subscribe/2`, `unsubscribe/2` or the list clause of
  `count_comments/2` — all three added in 0.2.8 — would raise. That gap is
  closed by the `>= 0.2.8` floor in `mix.exs`, not by any guard here.

  `:transfer` was added later (Plan 4/T15) — transfers have no Andi
  predecessor, but plug into the same `kind`-parameterized wrapper.
  """
  @compile {:no_warn_undefined, PhoenixKitComments}

  @resource_types %{
    goods_issue: "goods_issue",
    goods_receipt: "goods_receipt",
    internal_order: "internal_order",
    supplier_order: "supplier_order",
    inventory: "inventory",
    transfer: "transfer"
  }

  @type kind ::
          :goods_issue
          | :goods_receipt
          | :internal_order
          | :supplier_order
          | :inventory
          | :transfer

  @doc "The comment `resource_type` string used for the given document kind."
  @spec resource_type(kind()) :: String.t()
  def resource_type(kind) when is_map_key(@resource_types, kind),
    do: Map.fetch!(@resource_types, kind)

  @doc """
  True when the comments module is loadable and enabled. Says nothing about
  its *version* — see the moduledoc.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
  end

  @doc "Comment count for one document. Returns 0 when unavailable."
  @spec count(kind(), binary()) :: non_neg_integer()
  def count(kind, uuid) when is_binary(uuid) do
    if available?() do
      PhoenixKitComments.count_comments(resource_type(kind), uuid)
    else
      0
    end
  end

  @doc """
  Comment counts for many documents of the same kind, as a `uuid => count`
  map. Every requested uuid is present (value 0 when it has no comments).
  Returns an empty map when the module is unavailable.
  """
  @spec counts(kind(), [binary()]) :: %{optional(binary()) => non_neg_integer()}
  def counts(kind, uuids) when is_list(uuids) do
    if available?() and uuids != [] do
      PhoenixKitComments.count_comments(resource_type(kind), uuids)
    else
      %{}
    end
  end

  @doc """
  Subscribes the calling process to cross-session comment activity for the
  given document uuids. No-op when the module is unavailable.
  """
  @spec subscribe(kind(), [binary()]) :: :ok
  def subscribe(kind, uuids) when is_list(uuids) do
    if available?() do
      Enum.each(uuids, &PhoenixKitComments.subscribe(resource_type(kind), &1))
    end

    :ok
  end

  @doc "Unsubscribes the calling process from the given document uuids."
  @spec unsubscribe(kind(), [binary()]) :: :ok
  def unsubscribe(kind, uuids) when is_list(uuids) do
    if available?() do
      Enum.each(uuids, &PhoenixKitComments.unsubscribe(resource_type(kind), &1))
    end

    :ok
  end
end
