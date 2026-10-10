defmodule PhoenixKitWarehouse.GoodsReceipt do
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type Ecto.UUID

  @statuses ~w(draft posted)
  @external_ref_index :phoenix_kit_warehouse_goods_receipts_external_ref_index

  # Single shape authority for `PhoenixKitWarehouse.Migrations` — this width
  # coincides with core's V140 baseline shape, which `ExpectedSchema` audits;
  # changing it is a chain version (V2+), never a second hard-coded number in
  # the migration DDL.
  @column_widths %{status: 20}

  # Widths of the columns chain version 2 adds (see `GoodsIssue`).
  @v2_column_widths %{external_ref: 255}

  schema "phoenix_kit_warehouse_goods_receipts" do
    field(:number, :integer, read_after_writes: true)
    field(:status, :string, default: "draft")
    field(:supplier_order_uuid, Ecto.UUID)
    field(:supplier_uuid, Ecto.UUID)
    field(:location_uuid, Ecto.UUID)
    field(:note, :string)
    # Number of the document in an outside system; unique among posted,
    # non-deleted goods receipts (partial unique index, chain version 2).
    field(:external_ref, :string)
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
      :source_refs,
      :external_ref
    ])
    |> validate_required([:location_uuid])
    |> update_change(:external_ref, &PhoenixKitWarehouse.PostingSupport.trim_ref/1)
    |> validate_length(:external_ref, max: @v2_column_widths.external_ref, count: :codepoints)
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
    |> unique_constraint(:external_ref, name: @external_ref_index)
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
