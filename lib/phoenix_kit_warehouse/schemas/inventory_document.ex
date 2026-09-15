defmodule PhoenixKitWarehouse.InventoryDocument do
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type Ecto.UUID

  @statuses ~w(draft posted)

  # Single shape authority for `PhoenixKitWarehouse.Migrations` — this width
  # coincides with core's V140 baseline shape, which `ExpectedSchema` audits;
  # changing it is a chain version (V2+), never a second hard-coded number in
  # the migration DDL.
  @column_widths %{status: 20}

  schema "phoenix_kit_warehouse_inventory_documents" do
    field(:number, :integer, read_after_writes: true)
    field(:status, :string, default: "draft")
    field(:track_value, :boolean, default: false)
    # Warehouse the count is performed at. Defaults to the configured default
    # warehouse on creation; editable while the document is a draft (changing
    # it re-seeds :lines from the new warehouse's stock — see Inventories.update_draft/2).
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

  @doc """
  The `character varying(N)` widths `PhoenixKitWarehouse.Migrations` builds its
  `CREATE TABLE` DDL from — the single source of truth so the migration
  chain, this schema, and core's `ExpectedSchema` manifest can never
  independently disagree on a number.
  """
  @spec column_widths() :: %{atom() => pos_integer()}
  def column_widths, do: @column_widths

  @doc "Changeset for creating/editing draft inventory documents."
  def draft_changeset(doc, attrs) do
    doc
    |> cast(attrs, [:track_value, :note, :lines, :created_by_uuid, :location_uuid])
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
