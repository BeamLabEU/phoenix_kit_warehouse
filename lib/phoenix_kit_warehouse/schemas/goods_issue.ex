defmodule PhoenixKitWarehouse.GoodsIssue do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  @statuses ~w(draft posted)

  schema "phoenix_kit_warehouse_goods_issues" do
    field(:number, :integer, read_after_writes: true)
    field(:status, :string, default: "draft")
    field(:internal_order_uuid, Ecto.UUID)
    field(:location_uuid, Ecto.UUID)
    field(:note, :string)
    field(:storage_folder_uuid, Ecto.UUID)
    field(:lines, {:array, :map}, default: [])
    field(:source_refs, {:array, :map}, default: [])
    field(:created_by_uuid, Ecto.UUID)
    field(:performed_by_uuid, Ecto.UUID)
    field(:posted_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)
    field(:deleted_by_uuid, Ecto.UUID)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating/editing draft goods issues."
  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [
      :internal_order_uuid,
      :location_uuid,
      :note,
      :lines,
      :storage_folder_uuid,
      :source_refs
    ])
    |> validate_required([:location_uuid])
  end

  @doc "Changeset for posting a goods issue (programmatic fields only — no cast)."
  def post_changeset(issue, audited_lines, performed_by_uuid) do
    issue
    |> change(%{
      status: "posted",
      lines: audited_lines,
      posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      performed_by_uuid: performed_by_uuid
    })
  end

  @doc "Changeset for soft-deleting a goods issue."
  def soft_delete_changeset(issue, attrs) do
    issue
    |> cast(attrs, [:deleted_at, :deleted_by_uuid])
  end

  @doc "Changeset for correcting a posted goods issue (note + storage_folder only — lines immutable after posting)."
  def correction_changeset(issue, attrs) do
    issue
    |> cast(attrs, [:note, :storage_folder_uuid])
  end

  @doc "Changeset for setting the storage folder (programmatic — single field)."
  def storage_changeset(issue, attrs) do
    issue
    |> cast(attrs, [:storage_folder_uuid])
  end

  def statuses, do: @statuses
end
