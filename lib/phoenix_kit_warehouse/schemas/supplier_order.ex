defmodule PhoenixKitWarehouse.SupplierOrder do
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

  schema "phoenix_kit_warehouse_supplier_orders" do
    field(:number, :integer, read_after_writes: true)
    field(:status, :string, default: "draft")
    field(:supplier_uuid, Ecto.UUID)
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

  @doc """
  The `character varying(N)` widths `PhoenixKitWarehouse.Migrations` builds its
  `CREATE TABLE` DDL from — the single source of truth so the migration
  chain, this schema, and core's `ExpectedSchema` manifest can never
  independently disagree on a number.
  """
  @spec column_widths() :: %{atom() => pos_integer()}
  def column_widths, do: @column_widths

  @doc "Changeset for creating/editing draft supplier orders."
  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :supplier_uuid,
      :internal_order_uuid,
      :location_uuid,
      :note,
      :lines,
      :storage_folder_uuid,
      :source_refs
    ])
    |> validate_required([:location_uuid])
  end

  @doc """
  Changeset for posting a supplier order.

  Enforces that `supplier_uuid` is present — a supplier-less draft cannot be
  posted. Also sets status, posted_at and performed_by_uuid (programmatic only,
  no cast).
  """
  def post_changeset(order, performed_by_uuid) do
    order
    |> change(%{
      status: "posted",
      posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      performed_by_uuid: performed_by_uuid
    })
    |> validate_required([:supplier_uuid])
  end

  @doc "Changeset for soft-deleting a supplier order."
  def soft_delete_changeset(order, attrs) do
    order
    |> cast(attrs, [:deleted_at, :deleted_by_uuid])
  end

  @doc "Changeset for correcting a posted supplier order (note + storage_folder only — lines immutable after posting)."
  def correction_changeset(order, attrs) do
    order
    |> cast(attrs, [:note, :storage_folder_uuid])
  end

  @doc "Changeset for setting the storage folder (programmatic — single field)."
  def storage_changeset(order, attrs) do
    order
    |> cast(attrs, [:storage_folder_uuid])
  end

  def statuses, do: @statuses
end
