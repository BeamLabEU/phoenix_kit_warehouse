defmodule PhoenixKitWarehouse.Migrations.Postgres.V02 do
  @moduledoc false

  use Ecto.Migration

  def up(%{prefix: prefix}) do
    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix}.phoenix_kit_warehouse_min_stock (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      item_uuid UUID NOT NULL,
      min_quantity NUMERIC NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_min_stock_item_uuid_index
    ON #{prefix}.phoenix_kit_warehouse_min_stock (item_uuid)
    """)

    # Version marker lives on phoenix_kit_warehouse_stock — this module's own
    # table, guaranteed to exist by the time this runs — NOT on core's
    # `phoenix_kit` table, which is core's marker to manage exclusively.
    execute("COMMENT ON TABLE #{prefix}.phoenix_kit_warehouse_stock IS '2'")
  end

  def down(%{prefix: prefix}) do
    execute("DROP TABLE IF EXISTS #{prefix}.phoenix_kit_warehouse_min_stock")
    execute("COMMENT ON TABLE #{prefix}.phoenix_kit_warehouse_stock IS '1'")
  end
end
