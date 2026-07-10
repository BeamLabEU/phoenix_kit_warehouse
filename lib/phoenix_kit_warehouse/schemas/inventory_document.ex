defmodule PhoenixKitWarehouse.InventoryDocument do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  @statuses ~w(draft posted)

  schema "phoenix_kit_warehouse_inventory_documents" do
    field(:number, :integer, read_after_writes: true)
    field(:status, :string, default: "draft")
    field(:track_value, :boolean, default: false)
    # Warehouse the count was performed at. Set programmatically (defaults to
    # the configured default warehouse) — single-warehouse for now.
    field(:location_uuid, Ecto.UUID)
    field(:storage_folder_uuid, Ecto.UUID)
    field(:note, :string)
    field(:lines, {:array, :map}, default: [])
    field(:created_by_uuid, Ecto.UUID)
    field(:performed_by_uuid, Ecto.UUID)
    field(:posted_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)
    field(:deleted_by_uuid, Ecto.UUID)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating/editing draft inventory documents."
  def draft_changeset(doc, attrs) do
    doc
    |> cast(attrs, [:track_value, :note, :lines, :created_by_uuid])
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Changeset for correcting a posted or draft document (content only — does not change :status)."
  def correction_changeset(doc, attrs) do
    doc
    |> cast(attrs, [:track_value, :note, :lines])
  end

  @doc "Changeset for posting an inventory document (programmatic fields only — no cast)."
  def post_changeset(doc, audited_lines, performed_by_uuid) do
    doc
    |> change(%{
      status: "posted",
      posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      performed_by_uuid: performed_by_uuid,
      lines: audited_lines
    })
  end

  @doc "Changeset for soft-deleting an inventory document."
  def soft_delete_changeset(doc, attrs) do
    doc
    |> cast(attrs, [:deleted_at, :deleted_by_uuid])
  end

  @doc "Changeset for setting the storage folder (programmatic — single field)."
  def storage_changeset(doc, attrs) do
    doc
    |> cast(attrs, [:storage_folder_uuid])
  end

  @doc "Changeset for setting responsibility fields (created_by_uuid, performed_by_uuid)."
  def responsibility_changeset(doc, attrs) do
    doc
    |> cast(attrs, [:created_by_uuid, :performed_by_uuid])
  end

  def statuses, do: @statuses
end
