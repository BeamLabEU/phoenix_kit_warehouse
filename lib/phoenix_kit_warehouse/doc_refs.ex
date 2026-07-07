defmodule PhoenixKitWarehouse.DocRefs do
  @moduledoc """
  Resolves warehouse document UUIDs to human-readable labels and admin paths.

  All functions come in single (ref) and batch (refs) variants to avoid N+1
  queries when rendering index pages.

  Returned maps have the shape:
    %{label: "#IO-N", path: "/admin/andi/warehouse/internal-orders/<uuid>",
      uuid: "<uuid>", kind: :internal_order}

  `label`, `uuid`, and `kind` are always present; `path` is always absolute.
  `kind` is one of `:order`, `:sub_order`, `:internal_order`, `:supplier_order`,
  `:goods_receipt`, `:goods_issue` — useful for grouping a resolved list by tier.
  Functions return `nil` when the UUID is nil or the document does not exist.
  """

  import Ecto.Query

  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.SourceKinds
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKit.Utils.Routes

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # Top-level Orders
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a top-level order UUID to a label/path map.

  Returns `nil` when `uuid` is nil, not found, or the record is a sub-order
  (has a `parent_uuid`).
  """
  def order_ref(nil), do: nil

  def order_ref(uuid) do
    case SourceKinds.resolve("order", uuid) do
      %{label: label, path: path} -> %{label: label, path: path, uuid: uuid, kind: :order}
      :error -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Generic refs_for/1 — dispatches a source_refs list to per-type resolvers
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a list of source_ref maps to label/path maps.

  Each element must have shape `%{"type" => type, "uuid" => uuid}` where
  `type` is one of:
    - `"order"`          — top-level Andi order
    - `"sub_order"`      — Andi sub-order (parent_uuid not nil)
    - `"internal_order"` — warehouse internal order
    - `"supplier_order"` — warehouse supplier order
    - `"goods_receipt"`  — warehouse goods receipt
    - `"goods_issue"`    — warehouse goods issue

  Returns a list of `%{label, path}` maps, omitting any that resolve to nil
  (e.g. deleted or not-found documents).
  """
  def refs_for(source_refs) when is_list(source_refs) do
    source_refs
    |> Enum.map(fn
      %{"type" => "order", "uuid" => uuid} -> resolve_or_plain("order", uuid, :order)
      %{"type" => "sub_order", "uuid" => uuid} -> resolve_or_plain("sub_order", uuid, :sub_order)
      %{"type" => "internal_order", "uuid" => uuid} -> internal_order_ref(uuid)
      %{"type" => "supplier_order", "uuid" => uuid} -> supplier_order_ref(uuid)
      %{"type" => "goods_receipt", "uuid" => uuid} -> goods_receipt_ref(uuid)
      %{"type" => "goods_issue", "uuid" => uuid} -> goods_issue_ref(uuid)
      _ -> nil
    end)
    |> Enum.filter(& &1)
  end

  # Resolves an externally-owned ("order"/"sub_order") kind via SourceKinds,
  # falling back to a plain-UUID label rather than dropping the ref from the
  # list — an unresolvable ref (no source_kinds configured, or the host's
  # resolver errored) should still show *something* in an index/history view.
  defp resolve_or_plain(kind, uuid, kind_atom) do
    case SourceKinds.resolve(kind, uuid) do
      %{label: label, path: path} -> %{label: label, path: path, uuid: uuid, kind: kind_atom}
      :error -> %{label: uuid, path: nil, uuid: uuid, kind: kind_atom}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal Orders
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a single internal order UUID to a label/path map.
  Returns `nil` when `uuid` is nil or not found.
  """
  def internal_order_ref(nil), do: nil

  def internal_order_ref(uuid) do
    case InternalOrder |> where([o], o.uuid == ^uuid and is_nil(o.deleted_at)) |> repo().one() do
      nil -> nil
      order -> build_internal_order_ref(order)
    end
  end

  @doc """
  Batch resolves a list of internal order UUIDs.
  Returns `%{uuid => ref_map}` (absent uuids are omitted).
  """
  def internal_order_refs([]), do: %{}

  def internal_order_refs(uuids) do
    uuids = uuids |> Enum.filter(& &1) |> Enum.uniq()

    InternalOrder
    |> where([o], o.uuid in ^uuids and is_nil(o.deleted_at))
    |> select([o], %{uuid: o.uuid, number: o.number})
    |> repo().all()
    |> Map.new(fn row -> {row.uuid, build_internal_order_ref(row)} end)
  end

  # ---------------------------------------------------------------------------
  # Supplier Orders
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a single supplier order UUID to a label/path map.
  Returns `nil` when `uuid` is nil or not found.
  """
  def supplier_order_ref(nil), do: nil

  def supplier_order_ref(uuid) do
    case SupplierOrder |> where([o], o.uuid == ^uuid and is_nil(o.deleted_at)) |> repo().one() do
      nil -> nil
      order -> build_supplier_order_ref(order)
    end
  end

  @doc """
  Batch resolves a list of supplier order UUIDs.
  Returns `%{uuid => ref_map}`.
  """
  def supplier_order_refs([]), do: %{}

  def supplier_order_refs(uuids) do
    uuids = uuids |> Enum.filter(& &1) |> Enum.uniq()

    SupplierOrder
    |> where([o], o.uuid in ^uuids and is_nil(o.deleted_at))
    |> select([o], %{uuid: o.uuid, number: o.number})
    |> repo().all()
    |> Map.new(fn row -> {row.uuid, build_supplier_order_ref(row)} end)
  end

  # ---------------------------------------------------------------------------
  # Goods Receipts
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a single goods receipt UUID to a label/path map.
  Returns `nil` when `uuid` is nil or not found.
  """
  def goods_receipt_ref(nil), do: nil

  def goods_receipt_ref(uuid) do
    case GoodsReceipt |> where([r], r.uuid == ^uuid and is_nil(r.deleted_at)) |> repo().one() do
      nil -> nil
      receipt -> build_goods_receipt_ref(receipt)
    end
  end

  @doc """
  Batch resolves a list of goods receipt UUIDs.
  Returns `%{uuid => ref_map}`.
  """
  def goods_receipt_refs([]), do: %{}

  def goods_receipt_refs(uuids) do
    uuids = uuids |> Enum.filter(& &1) |> Enum.uniq()

    GoodsReceipt
    |> where([r], r.uuid in ^uuids and is_nil(r.deleted_at))
    |> select([r], %{uuid: r.uuid, number: r.number})
    |> repo().all()
    |> Map.new(fn row -> {row.uuid, build_goods_receipt_ref(row)} end)
  end

  # ---------------------------------------------------------------------------
  # Goods Issues
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a single goods issue UUID to a label/path map.
  Returns `nil` when `uuid` is nil or not found.
  """
  def goods_issue_ref(nil), do: nil

  def goods_issue_ref(uuid) do
    case GoodsIssue |> where([i], i.uuid == ^uuid and is_nil(i.deleted_at)) |> repo().one() do
      nil -> nil
      issue -> build_goods_issue_ref(issue)
    end
  end

  @doc """
  Batch resolves a list of goods issue UUIDs.
  Returns `%{uuid => ref_map}`.
  """
  def goods_issue_refs([]), do: %{}

  def goods_issue_refs(uuids) do
    uuids = uuids |> Enum.filter(& &1) |> Enum.uniq()

    GoodsIssue
    |> where([i], i.uuid in ^uuids and is_nil(i.deleted_at))
    |> select([i], %{uuid: i.uuid, number: i.number})
    |> repo().all()
    |> Map.new(fn row -> {row.uuid, build_goods_issue_ref(row)} end)
  end

  # ---------------------------------------------------------------------------
  # Sub-Orders (dispatched via SourceKinds)
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a sub-order UUID to a label/path map via `SourceKinds.resolve/2`.

  Returns `nil` when `uuid` is nil or SourceKinds returns `:error` (no host
  registered a `"sub_order"` resolver, or the document was not found).
  """
  def sub_order_ref(nil), do: nil

  def sub_order_ref(uuid) do
    case SourceKinds.resolve("sub_order", uuid) do
      %{label: label, path: path} -> %{label: label, path: path, uuid: uuid, kind: :sub_order}
      :error -> nil
    end
  end

  @doc """
  Batch resolves a list of sub-order UUIDs.
  Returns `%{uuid => ref_map}`.

  Note: resolves via individual `sub_order_ref/1` calls (one `SourceKinds.resolve/2`
  per uuid) rather than a single batched query, due to the SourceKinds single-uuid
  contract (Plan 2). Acceptable given typical list sizes; revisit in Plan 5 if
  query count becomes a problem in practice.
  """
  def sub_order_refs([]), do: %{}

  def sub_order_refs(uuids) do
    uuids
    |> Enum.filter(& &1)
    |> Enum.uniq()
    |> Enum.map(&{&1, sub_order_ref(&1)})
    |> Enum.filter(fn {_uuid, ref} -> ref end)
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Child document queries (for internal order detail view)
  # ---------------------------------------------------------------------------

  @doc """
  Returns all non-deleted supplier order refs where internal_order_uuid = the given uuid.
  Returns a list of ref maps `[%{label, path}]`.
  """
  def supplier_order_refs_for_internal_order(internal_order_uuid) do
    SupplierOrder
    |> where(
      [o],
      o.internal_order_uuid == ^internal_order_uuid and is_nil(o.deleted_at)
    )
    |> select([o], %{uuid: o.uuid, number: o.number})
    |> repo().all()
    |> Enum.map(&build_supplier_order_ref/1)
  end

  @doc """
  Returns all non-deleted goods issue refs where internal_order_uuid = the given uuid.
  Returns a list of ref maps `[%{label, path}]`.
  """
  def goods_issue_refs_for_internal_order(internal_order_uuid) do
    GoodsIssue
    |> where(
      [i],
      i.internal_order_uuid == ^internal_order_uuid and is_nil(i.deleted_at)
    )
    |> select([i], %{uuid: i.uuid, number: i.number})
    |> repo().all()
    |> Enum.map(&build_goods_issue_ref/1)
  end

  # ---------------------------------------------------------------------------
  # Private builders
  # ---------------------------------------------------------------------------

  defp build_internal_order_ref(%{uuid: uuid, number: number}) do
    %{
      label: "#IO-#{number}",
      path: Routes.path("/admin/andi/warehouse/internal-orders/#{uuid}"),
      uuid: uuid,
      kind: :internal_order
    }
  end

  defp build_supplier_order_ref(%{uuid: uuid, number: number}) do
    %{
      label: "#SO-#{number}",
      path: Routes.path("/admin/andi/warehouse/supplier-orders/#{uuid}"),
      uuid: uuid,
      kind: :supplier_order
    }
  end

  defp build_goods_receipt_ref(%{uuid: uuid, number: number}) do
    %{
      label: "#GR-#{number}",
      path: Routes.path("/admin/andi/warehouse/goods-receipts/#{uuid}"),
      uuid: uuid,
      kind: :goods_receipt
    }
  end

  defp build_goods_issue_ref(%{uuid: uuid, number: number}) do
    %{
      label: "#GI-#{number}",
      path: Routes.path("/admin/andi/warehouse/goods-issues/#{uuid}"),
      uuid: uuid,
      kind: :goods_issue
    }
  end
end
