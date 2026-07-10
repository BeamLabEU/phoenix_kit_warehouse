defmodule PhoenixKitWarehouse.GoodsReceipt do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  @statuses ~w(draft posted)

  schema "phoenix_kit_warehouse_goods_receipts" do
    field(:number, :integer, read_after_writes: true)
    field(:status, :string, default: "draft")
    field(:supplier_order_uuid, Ecto.UUID)
    field(:supplier_uuid, Ecto.UUID)
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

  @doc "Changeset for creating/editing draft goods receipts."
  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :supplier_order_uuid,
      :supplier_uuid,
      :location_uuid,
      :note,
      :lines,
      :storage_folder_uuid,
      :source_refs
    ])
    |> validate_required([:location_uuid])
  end

  @doc "Changeset for posting a goods receipt (programmatic fields only — no cast)."
  def post_changeset(receipt, audited_lines, performed_by_uuid) do
    receipt
    |> change(%{
      status: "posted",
      lines: audited_lines,
      posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      performed_by_uuid: performed_by_uuid
    })
  end

  @doc "Changeset for soft-deleting a goods receipt."
  def soft_delete_changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:deleted_at, :deleted_by_uuid])
  end

  @doc "Changeset for correcting a posted goods receipt (note + storage_folder only — lines immutable after posting)."
  def correction_changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:note, :storage_folder_uuid])
  end

  @doc "Changeset for setting the storage folder (programmatic — single field)."
  def storage_changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:storage_folder_uuid])
  end

  def statuses, do: @statuses
end
