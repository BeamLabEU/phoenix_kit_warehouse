defmodule PhoenixKitWarehouse.CommittedQuantities do
  @moduledoc """
  Computes, per source document, how much quantity per item has already been
  committed to non-deleted downstream documents referencing it — used so that
  selecting the same source into a second (or later) document only adds what's
  still outstanding, instead of duplicating the full original quantity.
  """

  import Ecto.Query

  alias PhoenixKitWarehouse.StockLedger

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Returns `%{source_uuid => %{item_uuid => Decimal}}` — for each uuid in
  `source_uuids`, the quantity already committed against it, summed across all
  non-deleted rows of `schema` whose `source_refs` contain a ref whose `"type"`
  is in `ref_types` and whose `"uuid"` matches.

  For refs recorded with a `"lines"` breakdown, uses that breakdown exactly.
  For legacy refs without one, falls back to attributing the document's own
  aggregate `lines` (keyed by `line_quantity_field`) to that ref — a safe
  overcount for the rare pre-existing multi-source merge.

  `opts`:
    * `:status` — when given, only rows of `schema` whose `status` field
      equals it are considered (in addition to the always-applied
      `is_nil(deleted_at)` filter). Omit (the default) to consider every
      non-deleted row regardless of status.

      Leave this unset for "avoid double-importing the same source into two
      documents" call sites (the common case) — that computation must
      include the document's own not-yet-posted draft (it's what makes a
      second import into the *same* still-draft document net out instead of
      duplicating). Pass `status: "posted"` only for call sites computing an
      actual on-hand/reservation effect, where a draft downstream document
      hasn't happened yet and so must not be netted out.
  """
  def compute(schema, ref_types, source_uuids, line_quantity_field, opts \\ []) do
    wanted = MapSet.new(source_uuids)
    status = Keyword.get(opts, :status)

    schema
    |> where([d], is_nil(d.deleted_at))
    |> maybe_filter_status(status)
    |> repo().all()
    |> Enum.reduce(%{}, fn doc, acc ->
      Enum.reduce(doc.source_refs || [], acc, fn ref, acc2 ->
        if ref["type"] in ref_types and MapSet.member?(wanted, ref["uuid"]) do
          lines = ref["lines"] || legacy_fallback_lines(doc, line_quantity_field)
          add_committed(acc2, ref["uuid"], lines)
        else
          acc2
        end
      end)
    end)
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [d], d.status == ^status)

  @doc """
  Merges a `{ref_type, source_uuid}` ref carrying `imported_lines`
  (`%{item_uuid => Decimal}`) into `existing_refs`. If a ref for that
  `{ref_type, source_uuid}` pair already exists, its `"lines"` map is summed
  with `imported_lines` in place — never skipped, never replaced — so the
  ref's `"lines"` always reflects the running cumulative total ever pulled
  from that source into this document.
  """
  def merge_ref(existing_refs, ref_type, source_uuid, imported_lines) do
    case Enum.find_index(existing_refs, &(&1["type"] == ref_type and &1["uuid"] == source_uuid)) do
      nil ->
        existing_refs ++ [%{"type" => ref_type, "uuid" => source_uuid, "lines" => imported_lines}]

      idx ->
        List.update_at(existing_refs, idx, fn ref ->
          prior = decimalize(ref["lines"] || %{})
          merged = Map.merge(prior, imported_lines, fn _item, a, b -> Decimal.add(a, b) end)
          Map.put(ref, "lines", merged)
        end)
    end
  end

  @doc """
  Whether `refs` hold a `{ref_type, source_uuid}` ref without a `"lines"`
  breakdown. `compute/5` nets such a ref as the whole document, so a later
  import must leave it as it is: `merge_ref/4` would turn it into "only what
  was imported", and the rest of the document would stop counting.
  """
  def whole_document_ref?(refs, ref_type, source_uuid) do
    Enum.any?(
      refs,
      &(&1["type"] == ref_type and &1["uuid"] == source_uuid and not is_map(&1["lines"]))
    )
  end

  defp legacy_fallback_lines(doc, field) do
    Map.new(doc.lines || [], fn line -> {line["item_uuid"], line[field]} end)
  end

  defp add_committed(acc, source_uuid, lines) do
    Map.update(acc, source_uuid, decimalize(lines), fn existing ->
      Map.merge(existing, decimalize(lines), fn _item, a, b -> Decimal.add(a, b) end)
    end)
  end

  defp decimalize(lines) do
    Map.new(lines, fn {item_uuid, qty} -> {item_uuid, StockLedger.to_decimal(qty)} end)
  end
end
