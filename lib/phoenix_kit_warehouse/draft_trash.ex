defmodule PhoenixKitWarehouse.DraftTrash do
  @moduledoc false
  # The locking and the move to the trash shared by every warehouse document
  # (internal and supplier orders, goods receipts and issues, inventory
  # documents, transfers: all their tables carry `status`, `number`,
  # `deleted_at`, `deleted_by_uuid` and `updated_at`).
  #
  # Callers lock the candidate rows (`lock_query/1`, one order of rows in every
  # operation so two of them cannot wait for each other) and then move them
  # with `trash_ids/3`, whose update repeats the conditions: a row that is no
  # longer a live draft is skipped. `trash_one/3` and `restore_one/2` do that
  # for one document. Nothing here writes activity; the caller does that after
  # the commit.

  import Ecto.Query

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Narrows a list query to the live rows, or to the trashed ones when `trashed?`
  is `true` (any other value means the live rows, the default of every list).
  """
  def scope(query, true), do: where(query, [o], not is_nil(o.deleted_at))
  def scope(query, _trashed?), do: where(query, [o], is_nil(o.deleted_at))

  @doc "Counts the trashed rows of `schema`, whatever their status."
  def count_trashed(schema) do
    from(o in schema, where: not is_nil(o.deleted_at), select: count(o.uuid))
    |> repo().one()
  end

  @doc """
  Takes a transaction-scoped advisory lock on `key` (released with the commit).
  Same technique as `PostingSupport.find_posted_by_external_ref/3`.
  """
  @spec advisory_lock!(String.t()) :: :ok
  def advisory_lock!(key) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  @doc "Orders the query by uuid and locks the rows FOR UPDATE."
  def lock_query(query), do: query |> order_by([o], asc: o.uuid) |> lock("FOR UPDATE")

  @doc "Locks the given rows of `schema` in uuid order and returns them."
  def lock_rows(schema, uuids) do
    from(o in schema, where: o.uuid in ^uuids)
    |> lock_query()
    |> repo().all()
  end

  @doc """
  Applies `changeset` to its row under the row lock, unless the row is in the
  trash by then (`{:error, :deleted}`; `{:error, :not_found}` when it is gone).
  For the writes that are not gated to drafts, which the status lock of the
  documents does not cover.

  `check` sees the locked live row before the write; anything but `:ok`
  (an `{:error, reason}`) rolls back with that reason.
  """
  def update_unless_trashed(
        schema,
        %Ecto.Changeset{data: %{uuid: uuid}} = changeset,
        check \\ fn _row -> :ok end
      ) do
    repo().transaction(fn ->
      case lock_rows(schema, [uuid]) do
        [%{deleted_at: nil} = row] ->
          with :ok <- check.(row),
               {:ok, updated} <- repo().update(changeset) do
            updated
          else
            {:error, reason} -> repo().rollback(reason)
          end

        [_trashed] ->
          repo().rollback(:deleted)

        [] ->
          repo().rollback(:not_found)
      end
    end)
  end

  @doc """
  Moves the rows with the given uuids to the trash, but only those that are
  still live drafts in the database. Returns the rows really updated (`select`
  plays the part of `returning`), sorted by number.
  """
  def trash_ids(_schema, [], _actor_uuid), do: []

  def trash_ids(schema, ids, actor_uuid) do
    now = now()

    {_count, trashed} =
      from(o in schema,
        where: o.uuid in ^ids and o.status == "draft" and is_nil(o.deleted_at),
        select: o
      )
      |> repo().update_all(set: [deleted_at: now, deleted_by_uuid: actor_uuid, updated_at: now])

    Enum.sort_by(trashed, & &1.number)
  end

  @doc """
  Moves one document to the trash in its own transaction: locks the row, then
  answers `{:error, :not_found}` for a missing row, `{:error, :deleted}` for
  one already in the trash and `{:error, :not_draft}` for any other status,
  as the database has them (not the caller's struct). Returns `{:ok, row}`.
  """
  @spec trash_one(module(), Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:ok, struct()} | {:error, :not_found | :deleted | :not_draft}
  def trash_one(schema, uuid, actor_uuid) do
    repo().transaction(fn ->
      case lock_rows(schema, [uuid]) do
        [] ->
          repo().rollback(:not_found)

        [%{deleted_at: %DateTime{}}] ->
          repo().rollback(:deleted)

        # The status is checked twice on purpose: here on the locked row, to
        # answer the right error, and again in the `trash_ids/3` update, so a
        # move stays draft-only even if this clause is ever lost.
        [%{status: status}] when status != "draft" ->
          repo().rollback(:not_draft)

        [_draft] ->
          case trash_ids(schema, [uuid], actor_uuid) do
            [trashed] -> trashed
            [] -> repo().rollback(:not_draft)
          end
      end
    end)
  end

  @doc """
  Brings one trashed draft back in its own transaction: locks the row, then
  answers `{:error, :not_found}` for a missing row, `{:error, :not_deleted}`
  for a live one and `{:error, :not_draft}` for a trashed document of another
  status (it stays in the trash). Returns `{:ok, row}`.
  """
  @spec restore_one(module(), Ecto.UUID.t()) ::
          {:ok, struct()} | {:error, :not_found | :not_deleted | :not_draft}
  def restore_one(schema, uuid) do
    repo().transaction(fn ->
      case lock_rows(schema, [uuid]) do
        [] ->
          repo().rollback(:not_found)

        [%{deleted_at: nil}] ->
          repo().rollback(:not_deleted)

        [%{status: status}] when status != "draft" ->
          repo().rollback(:not_draft)

        [_trashed_draft] ->
          case restore_row(schema, uuid) do
            nil -> repo().rollback(:not_draft)
            restored -> restored
          end
      end
    end)
  end

  @doc """
  The first step of a status-gated write: an `Ecto.Multi` that locks the row
  of `schema` FOR UPDATE under `:lock_status` while it is in `expected_status`.
  A draft must also be out of the trash. When a draft was expected, a miss on
  a row that is in the trash answers `:deleted`, whatever its status (a
  posted document trashed by older code included); any other miss answers the
  caller's `error`. Other expected statuses are not
  checked against the trash, so a legacy document trashed in another status
  can still finish its way.
  """
  @spec lock_status_step(module(), Ecto.UUID.t(), String.t(), atom()) :: Ecto.Multi.t()
  def lock_status_step(schema, uuid, expected_status, error) do
    Ecto.Multi.run(Ecto.Multi.new(), :lock_status, fn repo, _changes ->
      query =
        from(o in schema,
          where: o.uuid == ^uuid and o.status == ^expected_status,
          lock: "FOR UPDATE"
        )
        |> live_if_draft(expected_status)

      case repo.one(query) do
        nil -> {:error, miss_reason(repo, schema, uuid, expected_status, error)}
        locked -> {:ok, locked}
      end
    end)
  end

  defp live_if_draft(query, "draft"), do: where(query, [o], is_nil(o.deleted_at))
  defp live_if_draft(query, _status), do: query

  defp miss_reason(repo, schema, uuid, "draft", error) do
    case repo.get(schema, uuid) do
      %{deleted_at: %DateTime{}} -> :deleted
      _ -> error
    end
  end

  defp miss_reason(_repo, _schema, _uuid, _status, error), do: error

  @doc "Brings a trashed draft back; returns the row, or `nil` when it is not one."
  def restore_row(schema, uuid) do
    now = now()

    {_count, rows} =
      from(o in schema,
        where: o.uuid == ^uuid and o.status == "draft" and not is_nil(o.deleted_at),
        select: o
      )
      |> repo().update_all(set: [deleted_at: nil, deleted_by_uuid: nil, updated_at: now])

    List.first(rows)
  end

  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
