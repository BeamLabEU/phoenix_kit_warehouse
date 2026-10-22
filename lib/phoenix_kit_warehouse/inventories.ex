defmodule PhoenixKitWarehouse.Inventories do
  @moduledoc """
  Context for managing warehouse inventory documents.

  Provides draft CRUD, count-sheet seeding (active catalogue items only),
  and transactional posting via `Ecto.Multi`.
  """

  import Ecto.Query

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.ActivityLog
  alias PhoenixKitWarehouse.DraftTrash
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.PostingSupport
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitWarehouse.StockLedger

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ---------------------------------------------------------------------------
  # new_draft / seed_lines
  # ---------------------------------------------------------------------------

  @doc """
  Builds an unsaved inventory document struct pre-seeded with lines from the
  current stock at the configured default warehouse. Only items whose
  catalogue card has `status == "active"` are included.

  `locale` is explicit — do NOT rely on the process Gettext locale inside a
  context module.
  """
  def new_draft(locale, _opts \\ []) do
    location_uuid = StockLedger.default_location_uuid()
    lines = seed_lines(locale, location_uuid)
    %InventoryDocument{lines: lines, location_uuid: location_uuid}
  end

  @doc """
  Builds seed lines for a new inventory draft, scoped to a single warehouse.

  One line per stock row at `location_uuid` whose catalogue item exists AND
  has `status == "active"`. Fetches items via
  `PhoenixKitCatalogue.Catalogue.list_items_by_uuids/2` then filters
  `status == "active"` in Elixir (that function only excludes
  soft-deleted/status="deleted" items, so inactive/discontinued slip through).

  Each line is marked as seeded: `"counted_by" => "stock"`, with the stock it
  was seeded from in `"seeded_quantity"` - a seeded number is not a count,
  and the photo inventory replaces it rather than adding to it.
  """
  def seed_lines(locale, location_uuid) do
    stock_map = StockLedger.stock_map_for_location(location_uuid)
    item_uuids = Map.keys(stock_map)

    if item_uuids == [] do
      []
    else
      items_by_uuid =
        item_uuids
        |> Catalogue.list_items_by_uuids()
        |> Enum.filter(&(&1.status == "active"))
        |> Map.new(&{&1.uuid, &1})

      Enum.flat_map(item_uuids, fn item_uuid ->
        case Map.get(items_by_uuid, item_uuid) do
          nil ->
            []

          item ->
            stock_entry = stock_map[item_uuid]

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
                "counted_quantity" => stock_entry.quantity,
                "unit_value" => unit_value,
                "counted_by" => "stock",
                "seeded_quantity" => stock_entry.quantity
              }
            ]
        end
      end)
    end
  end

  # The host application's original `localized_name/2` is not a thin `PhoenixKitCatalogue.Catalogue`
  # wrapper — it combines `Catalogue.get_translation/2` with a host-specific
  # locale-code remap this generic package has
  # no access to. This private helper ports the actual translation-pick logic
  # (the part that IS generic) and drops only the host-specific remap step —
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

  # Always reached with a map: safe_get_translation/2 rescues to %{}, which is
  # the defensive layer here — a second non-map clause is unreachable and
  # dialyzer flags it as such.
  defp pick_name(translation) when is_map(translation) do
    case Map.get(translation, "_name") || Map.get(translation, "name") do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

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
  is not in `draft` status, `{:error, :deleted}` when it is in the trash.

  Changing `:location_uuid` to a value different from the document's current
  one always re-seeds `:lines` from that warehouse's current stock (see
  `seed_lines/2`), replacing whatever lines were there before — lines from
  the previous warehouse (manually counted or not) don't apply to a
  different physical location.

  Pass `:locale` (atom or string key) in `attrs` to localize the re-seeded
  line names; without it, re-seeded lines fall back to each catalogue item's
  default (untranslated) name — see `seed_lines/2`.

  Locks the row FOR UPDATE and re-checks status == "draft" in the DB (not
  just the in-memory struct) so a stale tab cannot overwrite a document that
  was posted concurrently by another tab/user.

  Options:

    * `:base_fingerprint` - the `fingerprint/1` of the warehouse and lines
      the caller's edit started from. Under the row lock it is compared with
      the warehouse and lines in the database; when they differ nothing
      is written and the answer is `{:error, :stale}`. On success the
      returned document carries the fingerprint of what was written in
      `:fingerprint`, the base of the caller's next save. A base passed as
      `nil` (a tab that has none) is refused as `:stale` too. Without the
      option nothing is compared and `:fingerprint` stays `nil`.
  """
  def update_draft(%InventoryDocument{uuid: uuid}, attrs, opts \\ []) do
    new_location_uuid = Map.get(attrs, :location_uuid) || Map.get(attrs, "location_uuid")
    base = Keyword.fetch(opts, :base_fingerprint)

    multi =
      uuid
      |> lock_status_step("draft", :not_draft)
      |> check_fingerprint_step(base)
      |> Ecto.Multi.update(:update, fn %{lock_status: locked} ->
        changeset = InventoryDocument.draft_changeset(locked, attrs)

        if new_location_uuid && new_location_uuid != locked.location_uuid do
          locale = Map.get(attrs, :locale) || Map.get(attrs, "locale")
          Ecto.Changeset.put_change(changeset, :lines, seed_lines(locale, new_location_uuid))
        else
          changeset
        end
      end)

    multi =
      if base == :error,
        do: multi,
        else:
          Ecto.Multi.run(multi, :fingerprint, fn repo, _ -> {:ok, fingerprint(uuid, repo)} end)

    case repo().transaction(multi) do
      {:ok, %{update: updated} = changes} ->
        {:ok, %{updated | fingerprint: changes[:fingerprint]}}

      {:error, _op, reason, _changes} ->
        {:error, reason}
    end
  end

  # `:error` - the option was not passed. A passed `nil` never matches: the
  # fingerprint of a live document is never `nil`.
  defp check_fingerprint_step(multi, :error), do: multi

  defp check_fingerprint_step(multi, {:ok, base_fingerprint}) do
    Ecto.Multi.run(multi, :check_fingerprint, fn repo, %{lock_status: locked} ->
      if is_binary(base_fingerprint) and fingerprint(locked.uuid, repo) == base_fingerprint,
        do: {:ok, :same},
        else: {:error, :stale}
    end)
  end

  @doc """
  The fingerprint of a document's warehouse and lines, taken in the
  database (jsonb text is canonical; the socket's maps - Decimals, other key
  order - are never fingerprinted). `nil` when the document is not there.
  The warehouse is included because two warehouses can have identical seed
  lines: counts from a tab on the old warehouse must not reach the new one.
  Read under a row lock it says whether the warehouse and lines are still
  the ones a tab started from (see `update_draft/3`).
  """
  @spec fingerprint(InventoryDocument.t() | Ecto.UUID.t(), Ecto.Repo.t() | nil) ::
          String.t() | nil
  def fingerprint(doc_or_uuid, target_repo \\ nil)

  def fingerprint(%InventoryDocument{uuid: uuid}, target_repo), do: fingerprint(uuid, target_repo)

  def fingerprint(uuid, target_repo) when is_binary(uuid) do
    from(d in InventoryDocument,
      where: d.uuid == ^uuid,
      select: fragment("md5(jsonb_build_array(?, ?)::text)", d.location_uuid, d.lines)
    )
    |> (target_repo || repo()).one()
  end

  @doc """
  The document and the fingerprint of its warehouse and lines, read in one query:
  `{:ok, doc}` with `doc.fingerprint` set, or `{:error, :not_found}`. A tab
  takes its base together with the lines it edits.
  """
  @spec get_document_with_fingerprint(Ecto.UUID.t()) ::
          {:ok, InventoryDocument.t()} | {:error, :not_found}
  def get_document_with_fingerprint(uuid) do
    from(d in InventoryDocument,
      where: d.uuid == ^uuid,
      select: {d, fragment("md5(jsonb_build_array(?, ?)::text)", d.location_uuid, d.lines)}
    )
    |> repo().one()
    |> case do
      nil -> {:error, :not_found}
      {doc, fingerprint} -> {:ok, %{doc | fingerprint: fingerprint}}
    end
  end

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

  `opts`:
    * `:trashed` (default `false`) - `true` lists the trashed documents
      instead (any status, same order), the content of the trash view.
  """
  def list_documents(opts) do
    InventoryDocument
    |> DraftTrash.scope(Keyword.get(opts, :trashed, false))
    |> order_by([d], desc: d.number)
    |> repo().all()
  end

  @doc "Counts the trashed inventory documents (any status)."
  @spec count_trashed_documents() :: non_neg_integer()
  def count_trashed_documents, do: DraftTrash.count_trashed(InventoryDocument)

  # ---------------------------------------------------------------------------
  # Soft delete
  # ---------------------------------------------------------------------------

  @doc """
  Soft-deletes a draft document (sends it to the trash).

  Locks the row and moves it only while it is still a live draft in the
  database, so a draft posted in another tab is not trashed from a stale
  struct. Returns `{:ok, doc}`, `{:error, :not_draft}` for posted documents,
  `{:error, :deleted}` when it is already in the trash and
  `{:error, :not_found}` for a row that no longer exists. Logged as
  `warehouse.inventory.trashed` after the commit.
  """
  @spec soft_delete_document(InventoryDocument.t(), Ecto.UUID.t() | nil) ::
          {:ok, InventoryDocument.t()} | {:error, :not_draft | :deleted | :not_found}
  def soft_delete_document(%InventoryDocument{status: "draft", uuid: uuid}, actor_uuid) do
    with {:ok, trashed} <- DraftTrash.trash_one(InventoryDocument, uuid, actor_uuid) do
      ActivityLog.log_inventory_trashed(trashed, actor_uuid: actor_uuid, reason: "manual")
      {:ok, trashed}
    end
  end

  def soft_delete_document(%InventoryDocument{}, _actor_uuid), do: {:error, :not_draft}

  @doc """
  Brings a trashed draft document back.

  Returns `{:ok, doc}`, `{:error, :not_deleted}` for a live one,
  `{:error, :not_draft}` for a trashed posted document (legacy; it stays in the
  trash) or `{:error, :not_found}`. Logged as `warehouse.inventory.restored`
  after the commit.
  """
  @spec restore_document(InventoryDocument.t(), Ecto.UUID.t() | nil) ::
          {:ok, InventoryDocument.t()} | {:error, :not_deleted | :not_draft | :not_found}
  def restore_document(%InventoryDocument{uuid: uuid}, actor_uuid) do
    with {:ok, restored} <- DraftTrash.restore_one(InventoryDocument, uuid) do
      ActivityLog.log_inventory_restored(restored, actor_uuid: actor_uuid)
      {:ok, restored}
    end
  end

  # ---------------------------------------------------------------------------
  # Posting
  # ---------------------------------------------------------------------------

  @doc """
  Posts an inventory document in an `Ecto.Multi` transaction.

  - Inside the transaction, locks the stock rows of the document's items at
    the document's own warehouse (`FOR UPDATE`) and reads them for the audit
    `previous_*` fields — read and write happen under one lock, so a
    concurrent stock change can neither slip between them nor leave a wrong
    prior quantity on the document. A row that does not exist yet cannot be
    locked, so missing rows are first claimed (`INSERT ... ON CONFLICT DO
    NOTHING` at quantity 0, overwritten by the count anyway).
  - For each line: coerces quantities/values to Decimal; captures pre-post
    stock as audit fields; upserts the stock row inside the same transaction.
  - Updates the document status to "posted" with `posted_at` and
    `performed_by_uuid`.
  - Returns `{:error, :not_draft}` if the document is not in draft status,
    `{:error, :deleted}` when it is in the trash.
  - Posts the lines and `track_value` of the row read under the status lock,
    not those of the struct passed in, so a stale struct cannot overwrite a
    concurrent edit of the draft.
  - Rolls back on any failure.

  Options:

    * `:base_fingerprint` - the `fingerprint/1` of the warehouse and lines
      the caller means to post (the save it just made). Under the row lock
      it is compared with the warehouse and lines in the database; when they
      differ nothing is posted and the answer is `{:error, :stale}`. A base
      passed as `nil` is refused as `:stale` too. Without the option nothing
      is compared.
  """
  def post_document(doc, performed_by_uuid, opts \\ [])

  def post_document(%InventoryDocument{status: status}, _performed_by_uuid, _opts)
      when status != "draft" do
    {:error, :not_draft}
  end

  def post_document(%InventoryDocument{} = doc, performed_by_uuid, opts) do
    # `lock_status_step` locks the row FOR UPDATE and re-checks status == "draft"
    # inside the transaction, turning draft→posted into an atomic compare-and-swap.
    # The in-memory guard above only sees the struct in hand; a concurrent or
    # repeated post of a stale draft struct is rejected here instead of silently
    # re-applying stock and clobbering the audit trail.
    multi =
      doc.uuid
      |> lock_status_step("draft", :not_draft)
      |> check_fingerprint_step(Keyword.fetch(opts, :base_fingerprint))
      |> Ecto.Multi.run(:document, fn repo, %{lock_status: locked} ->
        apply_counts_and_post(locked, performed_by_uuid, repo)
      end)

    case repo().transaction(multi) do
      {:ok, %{document: posted_doc}} -> {:ok, posted_doc}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Creates an inventory document and posts it in ONE transaction.

  `attrs` takes `:location_uuid` (default warehouse when absent), `:lines`
  (each `%{"item_uuid" => uuid, "counted_quantity" => qty}` with optional
  `"unit_value"`), `:track_value`, `:external_ref`, `:note` and
  `:created_by_uuid` (defaults to `performed_by_uuid`). Atom or string keys.
  Only the listed items are counted; every other stock row is left alone.

  Lines are validated before the document row is inserted, so a refused call
  leaves no draft behind and consumes no document number. The prior quantity
  recorded on each line is read inside the posting transaction (see
  `post_document/2`).

  Returns `{:ok, posted_document}`; `{:ok, :already_posted, existing}` when a
  posted, non-deleted inventory document already carries the same
  `external_ref` (nothing is written, and the lines are not compared with the
  existing document's); `{:error, {:duplicate_lines, item_uuids}}` (the plain
  post path silently keeps the first); `{:error, {:invalid_quantity,
  item_uuids}}` (a negative, missing, blank or unparseable counted quantity);
  `{:error, :no_lines | :invalid_lines}`; or `{:error, %Ecto.Changeset{}}`. A
  line's `"unit_value"` is passed through unchecked, as on the plain post
  path.

  With `skip_unchanged: true` a call whose lines all equal the stock already
  held creates no document: the answer is `{:error, :unchanged}` and nothing is
  written (the check runs under the same row locks as the posting, before the
  document number is drawn). A repeated `external_ref` is still answered first.
  """
  def create_and_post(attrs, performed_by_uuid, opts \\ []) when is_map(attrs) do
    PostingSupport.create_and_post(attrs, performed_by_uuid,
      schema: InventoryDocument,
      quantity_key: "counted_quantity",
      guard: unchanged_guard(Keyword.get(opts, :skip_unchanged, false)),
      changeset: fn attrs, created_by_uuid ->
        %InventoryDocument{}
        |> InventoryDocument.draft_changeset(attrs)
        # `create_draft/1` fills the location in after building its changeset,
        # so the schema changeset cannot require it; here it is known by now.
        |> Ecto.Changeset.validate_required([:location_uuid])
        |> Ecto.Changeset.put_change(:created_by_uuid, created_by_uuid)
        |> Ecto.Changeset.put_change(:performed_by_uuid, performed_by_uuid)
      end,
      post: &apply_counts_and_post(&2, performed_by_uuid, &1)
    )
  end

  defp unchanged_guard(false), do: fn _repo, _changeset -> {:ok, nil} end

  defp unchanged_guard(true) do
    fn repo, changeset ->
      lines = Ecto.Changeset.get_field(changeset, :lines)
      location_uuid = Ecto.Changeset.get_field(changeset, :location_uuid)
      track_value? = Ecto.Changeset.get_field(changeset, :track_value)
      prior_stock = locked_prior_stock(lines, location_uuid, repo)

      if Enum.all?(lines, &unchanged_line?(&1, prior_stock, track_value?)),
        do: {:error, :unchanged},
        else: {:ok, nil}
    end
  end

  # A line changes nothing when it counts the quantity already held and, on a
  # valued document, does not state another unit value (a line without one
  # leaves the stored value alone, see `upsert_counts/3`).
  defp unchanged_line?(line, prior_stock, track_value?) do
    prior =
      Map.get(prior_stock, line["item_uuid"], %{quantity: Decimal.new("0"), unit_value: nil})

    counted = StockLedger.to_decimal(line["counted_quantity"])
    stated = if track_value?, do: StockLedger.to_decimal_or_nil(line["unit_value"])

    Decimal.eq?(counted, prior.quantity) and
      (is_nil(stated) or (not is_nil(prior.unit_value) and Decimal.eq?(stated, prior.unit_value)))
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

  Mirrors `post_document/2` stock math exactly: reads current stock at the
  document's own warehouse, inside the transaction and under a row lock, for
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
    multi =
      Ecto.Multi.run(Ecto.Multi.new(), :document, fn repo, _changes ->
        apply_counts_and_post(doc, performed_by_uuid, repo)
      end)

    case repo().transaction(multi) do
      {:ok, %{document: reposted_doc}} -> {:ok, reposted_doc}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  # First step of a posting transaction: lock the document row FOR UPDATE and
  # assert it is still in `expected_status` (a draft also out of the trash).
  # Returns `{:error, error}` (aborting the transaction) when the row no longer
  # matches — i.e. a concurrent transaction already moved it, or it was posted
  # out from under a stale in-memory struct — and `{:error, :deleted}` for a
  # draft in the trash.
  defp lock_status_step(uuid, expected_status, error),
    do: DraftTrash.lock_status_step(InventoryDocument, uuid, expected_status, error)

  # The shared body of post_document/2, repost_document/2 and create_and_post/2.
  # Runs INSIDE the posting transaction: the prior stock is read under a row
  # lock taken in that same transaction, then the counts are written and the
  # document is stamped.
  defp apply_counts_and_post(%InventoryDocument{} = doc, performed_by_uuid, repo) do
    # Dedupe by item_uuid first: two lines with the same item would upsert the
    # same stock row twice and record a wrong prior quantity for the second.
    # Keep the first occurrence (the UI already prevents duplicates; this guards
    # any non-UI path; create_and_post/2 refuses duplicates outright).
    lines = Enum.uniq_by(doc.lines, & &1["item_uuid"])
    prior_stock = locked_prior_stock(lines, doc.location_uuid, repo)
    audited_lines = Enum.map(lines, &audit_line(&1, prior_stock))

    with :ok <- upsert_counts(audited_lines, doc, repo) do
      doc
      |> InventoryDocument.post_changeset(audited_lines, performed_by_uuid)
      |> repo.update()
    end
  end

  # Reads, under row locks, the stock rows the document is about to overwrite.
  #
  # `FOR UPDATE` cannot lock a row that does not exist yet, and a concurrent
  # transaction may insert it between this read and the write. So every
  # missing row is first claimed with an `ON CONFLICT DO NOTHING` insert at
  # quantity 0 (the count overwrites it anyway): after that, each row either
  # existed or was inserted by this transaction, and the locking read sees it.
  # Locks are taken in item order, as goods receipts and `create_and_post/2` of
  # goods issues take theirs, so these cannot deadlock one another. A goods
  # issue posted from a draft still locks in its own line order.
  defp locked_prior_stock(lines, location_uuid, repo) do
    # A malformed uuid is left out here, so the upsert reports it as a
    # changeset error (and rolls the transaction back) instead of the claim
    # insert raising on it.
    item_uuids =
      for line <- lines, {:ok, item_uuid} <- [Ecto.UUID.cast(line["item_uuid"])], do: item_uuid

    claim_missing_rows(item_uuids, location_uuid, repo)

    from(s in Stock,
      where: s.item_uuid in ^item_uuids and s.location_uuid == ^location_uuid,
      order_by: s.item_uuid,
      lock: "FOR UPDATE"
    )
    |> repo.all()
    |> Map.new(&{&1.item_uuid, %{quantity: &1.quantity, unit_value: &1.unit_value}})
  end

  defp claim_missing_rows([], _location_uuid, _repo), do: :ok

  defp claim_missing_rows(item_uuids, location_uuid, repo) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      item_uuids
      |> Enum.sort()
      |> Enum.map(fn item_uuid ->
        %{
          uuid: UUIDv7.generate(),
          item_uuid: item_uuid,
          location_uuid: location_uuid,
          quantity: Decimal.new("0"),
          inserted_at: now,
          updated_at: now
        }
      end)

    repo.insert_all(Stock, rows,
      on_conflict: :nothing,
      conflict_target: [:item_uuid, :location_uuid]
    )

    :ok
  end

  defp audit_line(line, prior_stock) do
    prior = Map.get(prior_stock, line["item_uuid"])

    Map.merge(line, %{
      "previous_quantity" => if(prior, do: prior.quantity, else: Decimal.new("0")),
      "previous_unit_value" => if(prior, do: prior.unit_value, else: nil)
    })
  end

  defp upsert_counts(audited_lines, doc, repo) do
    Enum.reduce_while(audited_lines, :ok, fn line, :ok ->
      unit_value_opt =
        if doc.track_value, do: StockLedger.to_decimal_or_nil(line["unit_value"]), else: nil

      result =
        StockLedger.upsert_quantity(
          line["item_uuid"],
          StockLedger.to_decimal(line["counted_quantity"]),
          unit_value: unit_value_opt,
          location_uuid: doc.location_uuid,
          repo: repo
        )

      case result do
        {:ok, _stock} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
