defmodule PhoenixKitWarehouse.Transfer do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type Ecto.UUID

  @statuses ~w(draft in_transit done cancelled)

  schema "phoenix_kit_warehouse_transfers" do
    field(:number, :integer, read_after_writes: true)
    field(:status, :string, default: "draft")
    field(:source_location_uuid, Ecto.UUID)
    field(:destination_location_uuid, Ecto.UUID)
    field(:note, :string)
    field(:storage_folder_uuid, Ecto.UUID)
    field(:lines, {:array, :map}, default: [])
    field(:source_refs, {:array, :map}, default: [])
    field(:created_by_uuid, Ecto.UUID)
    field(:performed_by_uuid, Ecto.UUID)
    field(:shipped_at, :utc_datetime)
    field(:received_at, :utc_datetime)
    field(:cancelled_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)
    field(:deleted_by_uuid, Ecto.UUID)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating/editing a draft transfer. Both locations may be
  `nil` at this stage — the keeper hasn't necessarily chosen the source and
  destination warehouses yet. They only become mandatory when shipping
  (see `ship_changeset/3`).
  """
  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [
      :source_location_uuid,
      :destination_location_uuid,
      :note,
      :lines,
      :storage_folder_uuid,
      :source_refs
    ])
  end

  @doc """
  Changeset for shipping a transfer (draft -> in_transit, programmatic
  fields only — no cast). Requires both locations to already be set on the
  record (chosen earlier via `changeset/2`) and requires them to differ
  from each other.

  Note: `source_location_uuid`/`destination_location_uuid` are not part of
  this changeset's own changes (they're read from `transfer`'s existing
  data, unchanged), so the distinctness check is implemented via
  `get_field/2` + `add_error/3` rather than `validate_change/3` — the
  latter only inspects `changeset.changes` and never fires for a field that
  isn't being changed. Mirrors the `validate_no_self_parent`/
  `validate_not_self_parent` idiom used elsewhere in the PhoenixKit
  ecosystem (`phoenix_kit_locations/schemas/space.ex`,
  `phoenix_kit_catalogue/schemas/category.ex`).
  """
  def ship_changeset(transfer, audited_lines, performed_by_uuid) do
    transfer
    |> change(%{
      status: "in_transit",
      lines: audited_lines,
      shipped_at: DateTime.utc_now() |> DateTime.truncate(:second),
      performed_by_uuid: performed_by_uuid
    })
    |> validate_required([:source_location_uuid, :destination_location_uuid])
    |> validate_distinct_locations()
  end

  @doc """
  Changeset for receiving a transfer (in_transit -> done, programmatic
  fields only — no cast). Locations are already guaranteed to be set at
  this point (the transfer went through `ship_changeset/3` first), but the
  same `validate_required/2` is applied here too for symmetry and as a
  guard against data corruption.
  """
  def receive_changeset(transfer, audited_lines, performed_by_uuid) do
    transfer
    |> change(%{
      status: "done",
      lines: audited_lines,
      received_at: DateTime.utc_now() |> DateTime.truncate(:second),
      performed_by_uuid: performed_by_uuid
    })
    |> validate_required([:source_location_uuid, :destination_location_uuid])
  end

  @doc """
  Changeset for cancelling a transfer (from `draft` or `in_transit`,
  programmatic fields only — no cast). `attrs` carries `:performed_by_uuid`
  and, only when cancelling from `in_transit`, `:lines` — the
  reverse-posting audit snapshot (see
  `PhoenixKitWarehouse.Transfers.cancel_transfer/2`). Cancelling from
  `draft` never touches `:lines` since no stock movement happened yet.
  """
  def cancel_changeset(transfer, attrs) do
    base = %{
      status: "cancelled",
      cancelled_at: DateTime.utc_now() |> DateTime.truncate(:second),
      performed_by_uuid: Map.get(attrs, :performed_by_uuid)
    }

    changes =
      case Map.fetch(attrs, :lines) do
        {:ok, lines} -> Map.put(base, :lines, lines)
        :error -> base
      end

    change(transfer, changes)
  end

  @doc "Changeset for soft-deleting a transfer."
  def soft_delete_changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [:deleted_at, :deleted_by_uuid])
  end

  @doc "Changeset for correcting a transfer (note + storage_folder only — lines/locations immutable once shipped)."
  def correction_changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [:note, :storage_folder_uuid])
  end

  @doc "Changeset for setting the storage folder (programmatic — single field)."
  def storage_changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [:storage_folder_uuid])
  end

  defp validate_distinct_locations(changeset) do
    source = get_field(changeset, :source_location_uuid)
    destination = get_field(changeset, :destination_location_uuid)

    if source != nil and destination != nil and source == destination do
      add_error(changeset, :destination_location_uuid, "must differ from the source location")
    else
      changeset
    end
  end

  def statuses, do: @statuses
end
