defmodule PhoenixKitWarehouse.Stock do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "phoenix_kit_warehouse_stock" do
    field(:item_uuid, Ecto.UUID)
    # The warehouse location holding this balance. Defaults (in the context) to
    # the configured default warehouse — the app is single-warehouse for now.
    field(:location_uuid, Ecto.UUID)
    field(:quantity, :decimal)
    field(:unit_value, :decimal)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for warehouse stock rows."
  def changeset(stock, attrs) do
    stock
    |> cast(attrs, [:item_uuid, :location_uuid, :quantity, :unit_value])
    |> validate_required([:item_uuid, :location_uuid, :quantity])
    |> validate_number(:quantity, greater_than_or_equal_to: 0)
    |> unique_constraint(:item_uuid,
      name: :phoenix_kit_warehouse_stock_item_location_index
    )
  end
end
