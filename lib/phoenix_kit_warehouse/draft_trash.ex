defmodule PhoenixKitWarehouse.DraftTrash do
  @moduledoc false
  # The locking and the move to the trash that "one draft per source" shares
  # between internal orders and supplier orders (both tables carry `status`,
  # `number`, `deleted_at`, `deleted_by_uuid` and `updated_at`).
  #
  # Callers lock the candidate rows (`lock_query/1`, one order of rows in every
  # operation so two of them cannot wait for each other) and then move them
  # with `trash_ids/3`, whose update repeats the conditions: a row that is no
  # longer a live draft is skipped. Nothing here writes activity; the caller
  # does that after the commit.

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
  """
  def update_unless_trashed(schema, %Ecto.Changeset{data: %{uuid: uuid}} = changeset) do
    repo().transaction(fn ->
      case lock_rows(schema, [uuid]) do
        [%{deleted_at: nil}] ->
          case repo().update(changeset) do
            {:ok, updated} -> updated
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
