defmodule PhoenixKitWarehouse.InventoryDocument do
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type Ecto.UUID

  @statuses ~w(draft posted)
  @external_ref_index :phoenix_kit_warehouse_inventory_documents_external_ref_index

  # Single shape authority for `PhoenixKitWarehouse.Migrations` — this width
  # coincides with core's V140 baseline shape, which `ExpectedSchema` audits;
  # changing it is a chain version (V2+), never a second hard-coded number in
  # the migration DDL.
  @column_widths %{status: 20}

  # Widths of the columns chain version 2 adds (see `GoodsIssue`).
  @v2_column_widths %{external_ref: 255}

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
    # Number of the document in an outside system; unique among posted,
    # non-deleted inventory documents (partial unique index, chain version 2).
    field(:external_ref, :string)
    field(:lines, {:array, :map}, default: [])
    field(:created_by_uuid, Ecto.UUID)
    field(:performed_by_uuid, Ecto.UUID)
    field(:posted_at, :utc_datetime)
    field(:deleted_at, :utc_datetime)
    field(:deleted_by_uuid, Ecto.UUID)
    # `md5(lines::text)` as the database computed it when the document was
    # read or written by `Inventories.get_document_with_fingerprint/1` or
    # `Inventories.update_draft/3` with `base_fingerprint:`; `nil` otherwise.
    field(:fingerprint, :string, virtual: true)

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

  @doc "Widths of the columns added by chain version 2 (`external_ref`)."
  @spec v2_column_widths() :: %{atom() => pos_integer()}
  def v2_column_widths, do: @v2_column_widths

  @doc "Changeset for creating/editing draft inventory documents."
  def draft_changeset(doc, attrs) do
    doc
    |> cast(attrs, [
      :track_value,
      :note,
      :lines,
      :created_by_uuid,
      :location_uuid,
      :external_ref
    ])
    |> validate_inclusion(:status, @statuses)
    |> update_change(:external_ref, &PhoenixKitWarehouse.PostingSupport.trim_ref/1)
    |> validate_length(:external_ref, max: @v2_column_widths.external_ref, count: :codepoints)
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
    |> unique_constraint(:external_ref, name: @external_ref_index)
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
