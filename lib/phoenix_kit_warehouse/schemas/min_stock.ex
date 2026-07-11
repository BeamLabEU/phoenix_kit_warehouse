defmodule PhoenixKitWarehouse.MinStock do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "phoenix_kit_warehouse_min_stock" do
    field(:item_uuid, Ecto.UUID)
    field(:min_quantity, :decimal, default: Decimal.new("0"))

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a per-item minimum stock threshold row."
  def changeset(min_stock, attrs) do
    min_stock
    |> cast(attrs, [:item_uuid, :min_quantity])
    |> validate_required([:item_uuid, :min_quantity])
    |> validate_number(:min_quantity, greater_than_or_equal_to: 0)
    |> unique_constraint(:item_uuid, name: :phoenix_kit_warehouse_min_stock_item_uuid_index)
  end
end
