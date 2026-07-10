defmodule PhoenixKitWarehouse.Inventories do
  @moduledoc """
  Context for managing warehouse inventory documents.

  Provides draft CRUD, count-sheet seeding (active catalogue items only),
  and transactional posting via `Ecto.Multi`.
  """

  import Ecto.Query

  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitCatalogue.Catalogue

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # new_draft / seed_lines
  # ---------------------------------------------------------------------------

  @doc """
  Builds an unsaved inventory document struct pre-seeded with lines from the
  current stock. Only items whose catalogue card has `status == "active"` are
  included.

  `locale` is explicit — do NOT rely on the process Gettext locale inside a
  context module.
  """
  def new_draft(locale, _opts \\ []) do
    lines = seed_lines(locale)
    %InventoryDocument{lines: lines, location_uuid: StockLedger.default_location_uuid()}
  end

  @doc """
  Builds seed lines for a new inventory draft.

  One line per stock row whose catalogue item exists AND has
  `status == "active"`. Fetches items via
  `PhoenixKitCatalogue.Catalogue.list_items_by_uuids/2` then filters
  `status == "active"` in Elixir (that function only excludes
  soft-deleted/status="deleted" items, so inactive/discontinued slip through).
  """
  def seed_lines(locale) do
    stock_rows = StockLedger.list_stock()
    item_uuids = Enum.map(stock_rows, & &1.item_uuid)

    if item_uuids == [] do
      []
    else
      items_by_uuid =
        item_uuids
        |> Catalogue.list_items_by_uuids()
        |> Enum.filter(&(&1.status == "active"))
        |> Map.new(&{&1.uuid, &1})

      stock_map = StockLedger.stock_map()

      Enum.flat_map(stock_rows, fn row ->
        case Map.get(items_by_uuid, row.item_uuid) do
          nil ->
            []

          item ->
            stock_entry = stock_map[row.item_uuid]

            unit_value =
              (stock_entry && stock_entry.unit_value) ||
                StockLedger.to_decimal_or_nil(item.base_price)

            [
              %{
                "item_uuid" => item.uuid,
                "name" => localized_name(item, locale),
                "sku" => item.sku,
                "category_uuid" => item.category_uuid,
                "catalogue_uuid" => item.catalogue_uuid,
                "unit" => item.unit,
                "counted_quantity" => row.quantity,
                "unit_value" => unit_value
              }
            ]
        end
      end)
    end
  end

  # `Andi.Catalogues.localized_name/2` is not a thin `PhoenixKitCatalogue.Catalogue`
  # wrapper — it combines `Catalogue.get_translation/2` with an Andi-specific
  # locale-code remap (`Andi.Locales.entity_locale/1`) this generic package has
  # no access to. This private helper ports the actual translation-pick logic
  # (the part that IS generic) and drops only the Andi-specific remap step —
  # callers already pass an explicit locale string (see the moduledoc above:
  # "do NOT rely on the process Gettext locale"), so the raw string is used
  # as-is against `Catalogue.get_translation/2` instead of being remapped
  # through a host-specific locale table first.
  defp localized_name(nil, _locale), do: nil

  defp localized_name(record, locale) do
    translation = safe_get_translation(record, locale)
    pick_name(translation) || Map.get(record, :name)
  end

  defp safe_get_translation(record, locale) do
    Catalogue.get_translation(record, locale)
  rescue
    _ -> %{}
  end

  defp pick_name(translation) when is_map(translation) do
    case Map.get(translation, "_name") || Map.get(translation, "name") do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp pick_name(_), do: nil

  # ---------------------------------------------------------------------------
  # Draft CRUD
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new draft inventory document.

  `location_uuid` is set programmatically — from `attrs` when given, otherwise
  the configured default warehouse (the column is NOT NULL).

  `performed_by_uuid` (the responsible person) defaults to the creator
  (`created_by_uuid`) for a new document, unless given explicitly.
  """
  def create_draft(attrs) do
    location_uuid =
      Map.get(attrs, :location_uuid) || Map.get(attrs, "location_uuid") ||
        StockLedger.default_location_uuid()

    created_by_uuid = Map.get(attrs, :created_by_uuid) || Map.get(attrs, "created_by_uuid")

    performed_by_uuid =
      Map.get(attrs, :performed_by_uuid) || Map.get(attrs, "performed_by_uuid") ||
        created_by_uuid

    %InventoryDocument{}
    |> InventoryDocument.draft_changeset(attrs)
    |> Ecto.Changeset.put_change(:location_uuid, location_uuid)
    |> Ecto.Changeset.put_change(:performed_by_uuid, performed_by_uuid)
    |> repo().insert()
  end

  @doc """
  Updates a draft document. Returns `{:error, :not_draft}` if the document
  is not in `draft` status.
  """
  def update_draft(%InventoryDocument{status: "draft"} = doc, attrs) do
    doc
    |> InventoryDocument.draft_changeset(attrs)
    |> repo().update()
  end

  def update_draft(%InventoryDocument{}, _attrs), do: {:error, :not_draft}

  @doc "Returns `{:ok, doc}` or `{:error, :not_found}`."
  def get_document(uuid) do
    case repo().get(InventoryDocument, uuid) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  @doc "Returns the document or raises."
  def get_document!(uuid), do: repo().get!(InventoryDocument, uuid)

  @doc """
  Lists non-deleted inventory documents. Ordered by number descending
  (newest first).
  """
  def list_documents(_opts) do
    InventoryDocument
    |> where([d], is_nil(d.deleted_at))
    |> order_by([d], desc: d.number)
    |> repo().all()
  end

  # ---------------------------------------------------------------------------
  # Soft delete
  # ---------------------------------------------------------------------------

  @doc "Soft-deletes a draft document. Returns {:error, :not_draft} for posted documents."
  def soft_delete_document(%InventoryDocument{status: "draft"} = doc, actor_uuid) do
    doc
    |> InventoryDocument.soft_delete_changeset(%{
      deleted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      deleted_by_uuid: actor_uuid
    })
    |> repo().update()
  end

  def soft_delete_document(%InventoryDocument{}, _actor_uuid), do: {:error, :not_draft}

  # ---------------------------------------------------------------------------
  # Posting
  # ---------------------------------------------------------------------------

  @doc """
  Posts an inventory document in an `Ecto.Multi` transaction.

  - Reads current `stock_map()` once up front for audit `previous_*` fields.
  - For each line: coerces quantities/values to Decimal; captures pre-post
    stock as audit fields; upserts the stock row inside the transaction via
    `Multi.run/3` (so all writes happen atomically).
  - Updates the document status to "posted" with `posted_at` and
    `performed_by_uuid`.
  - Returns `{:error, :not_draft}` if the document is not in draft status.
  - Rolls back on any failure.
  """
  def post_document(%InventoryDocument{status: status}, _performed_by_uuid)
      when status != "draft" do
    {:error, :not_draft}
  end

  def post_document(%InventoryDocument{} = doc, performed_by_uuid) do
    prior_stock = StockLedger.stock_map()
    {audited_lines, upserts} = build_posting_multi(doc, prior_stock)
    posted_changeset = InventoryDocument.post_changeset(doc, audited_lines, performed_by_uuid)

    # `lock_status_step` locks the row FOR UPDATE and re-checks status == "draft"
    # inside the transaction, turning draft→posted into an atomic compare-and-swap.
    # The in-memory guard above only sees the struct in hand; a concurrent or
    # repeated post of a stale draft struct is rejected here instead of silently
    # re-applying stock and clobbering the audit trail.
    multi =
      doc.uuid
      |> lock_status_step("draft", :not_draft)
      |> Ecto.Multi.append(upserts)
      |> Ecto.Multi.update(:document, posted_changeset)

    case repo().transaction(multi) do
      {:ok, %{document: posted_doc}} -> {:ok, posted_doc}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Corrects the content (`:track_value`, `:note`, `:lines`) of an inventory
  document without changing its status or touching stock.

  Works on documents in any status. Returns `{:ok, doc}` or
  `{:error, changeset}`.
  """
  def correct_document(%InventoryDocument{} = doc, attrs) do
    doc
    |> InventoryDocument.correction_changeset(attrs)
    |> repo().update()
  end

  @doc """
  Re-applies ABSOLUTE stock quantities for an already-posted document.

  Mirrors `post_document/2` stock math exactly: reads current stock for
  audit `previous_*` fields, upserts each line atomically, and re-stamps
  `posted_at` + `performed_by_uuid`.

  Returns `{:error, :not_posted}` when the document is not in `posted`
  status. Rolls back on any failure.
  """
  def repost_document(%InventoryDocument{status: status}, _performed_by_uuid)
      when status != "posted" do
    {:error, :not_posted}
  end

  def repost_document(%InventoryDocument{} = doc, performed_by_uuid) do
    prior_stock = StockLedger.stock_map()
    {audited_lines, multi} = build_posting_multi(doc, prior_stock)

    repost_changeset = InventoryDocument.post_changeset(doc, audited_lines, performed_by_uuid)
    multi = Ecto.Multi.update(multi, :document, repost_changeset)

    case repo().transaction(multi) do
      {:ok, %{document: reposted_doc}} -> {:ok, reposted_doc}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  # First step of a posting transaction: lock the document row FOR UPDATE and
  # assert it is still in `expected_status`. Returns `{:error, error}` (aborting
  # the transaction) when the row no longer matches — i.e. a concurrent
  # transaction already moved it, or it was posted/deleted out from under a stale
  # in-memory struct.
  defp lock_status_step(uuid, expected_status, error) do
    Ecto.Multi.run(Ecto.Multi.new(), :lock_status, fn repo, _changes ->
      query =
        from(d in InventoryDocument,
          where: d.uuid == ^uuid and d.status == ^expected_status,
          lock: "FOR UPDATE"
        )

      case repo.one(query) do
        nil -> {:error, error}
        %InventoryDocument{} = locked -> {:ok, locked}
      end
    end)
  end

  # Builds the audit lines (with previous_* snapshot) and the Multi of
  # per-line stock upserts shared by post_document/2 and repost_document/2.
  defp build_posting_multi(%InventoryDocument{} = doc, prior_stock) do
    # Dedupe by item_uuid first: two lines with the same item would collide on
    # the Ecto.Multi op name {:upsert_stock, item_uuid} and crash the posting.
    # Keep the first occurrence (the UI already prevents duplicates; this guards
    # any non-UI path).
    lines = Enum.uniq_by(doc.lines, & &1["item_uuid"])

    audited_lines =
      Enum.map(lines, fn line ->
        item_uuid = line["item_uuid"]
        prior = Map.get(prior_stock, item_uuid)

        previous_quantity = if prior, do: prior.quantity, else: Decimal.new("0")
        previous_unit_value = if prior, do: prior.unit_value, else: nil

        Map.merge(line, %{
          "previous_quantity" => previous_quantity,
          "previous_unit_value" => previous_unit_value
        })
      end)

    multi =
      Enum.reduce(audited_lines, Ecto.Multi.new(), fn line, multi ->
        item_uuid = line["item_uuid"]
        counted_quantity = StockLedger.to_decimal(line["counted_quantity"])

        unit_value_opt =
          if doc.track_value do
            StockLedger.to_decimal_or_nil(line["unit_value"])
          else
            nil
          end

        op_name = {:upsert_stock, item_uuid}

        Ecto.Multi.run(multi, op_name, fn repo, _changes ->
          StockLedger.upsert_quantity(item_uuid, counted_quantity,
            unit_value: unit_value_opt,
            location_uuid: doc.location_uuid,
            repo: repo
          )
        end)
      end)

    {audited_lines, multi}
  end

  # ---------------------------------------------------------------------------
  # Storage folder / responsibility
  # ---------------------------------------------------------------------------

  @doc """
  Sets the `storage_folder_uuid` on an inventory document.

  Works on documents in any status; returns `{:ok, doc}` or `{:error, changeset}`.
  """
  def set_storage_folder(%InventoryDocument{} = doc, storage_folder_uuid) do
    doc
    |> InventoryDocument.storage_changeset(%{storage_folder_uuid: storage_folder_uuid})
    |> repo().update()
  end

  @doc """
  Updates `created_by_uuid` and/or `performed_by_uuid` on an inventory document.

  Accepts a map with string or atom keys. Works on documents in any status.
  Returns `{:ok, doc}` or `{:error, changeset}`.
  """
  def update_responsibility(%InventoryDocument{} = doc, attrs) do
    doc
    |> InventoryDocument.responsibility_changeset(attrs)
    |> repo().update()
  end

  # ---------------------------------------------------------------------------
  # Totals
  # ---------------------------------------------------------------------------

  @doc "Computes `counted_quantity * unit_value` for a single line map."
  def line_total(line) do
    qty = StockLedger.to_decimal(line["counted_quantity"])
    uv = StockLedger.to_decimal_or_nil(line["unit_value"])

    if uv do
      Decimal.mult(qty, uv)
    else
      Decimal.new("0")
    end
  end

  @doc "Sums `line_total/1` across all lines in the document."
  def document_total(%InventoryDocument{lines: lines}) do
    Enum.reduce(lines, Decimal.new("0"), fn line, acc ->
      Decimal.add(acc, line_total(line))
    end)
  end
end
