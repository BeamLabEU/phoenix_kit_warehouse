defmodule PhoenixKitWarehouse.InternalOrder do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  @statuses ~w(draft posted)

  schema "phoenix_kit_warehouse_internal_orders" do
    field(:number, :integer, read_after_writes: true)
    field(:status, :string, default: "draft")
    field(:location_uuid, Ecto.UUID)
    field(:note, :string)
    field(:lines, {:array, :map}, default: [])
    field(:source_refs, {:array, :map}, default: [])
    field(:created_by_uuid, Ecto.UUID)
    field(:performed_by_uuid, Ecto.UUID)
    field(:posted_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)
    field(:deleted_by_uuid, Ecto.UUID)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating/editing draft internal orders."
  def changeset(order, attrs) do
    order
    |> cast(attrs, [:location_uuid, :note, :lines, :source_refs])
    |> validate_required([:location_uuid])
  end

  @doc "Changeset for posting an internal order (programmatic fields only — no cast)."
  def post_changeset(order, performed_by_uuid) do
    order
    |> change(%{
      status: "posted",
      posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      performed_by_uuid: performed_by_uuid
    })
  end

  @doc "Changeset for soft-deleting an internal order."
  def soft_delete_changeset(order, attrs) do
    order
    |> cast(attrs, [:deleted_at, :deleted_by_uuid])
  end

  @doc "Changeset for correcting a posted internal order (note only — no line edits after posting)."
  def correction_changeset(order, attrs) do
    order
    |> cast(attrs, [:note])
  end

  def statuses, do: @statuses
end
