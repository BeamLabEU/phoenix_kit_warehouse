defmodule PhoenixKitWarehouse.Migrations.Postgres.V01 do
  @moduledoc false

  use Ecto.Migration

  def up(%{prefix: prefix}) do
    execute("CREATE SEQUENCE IF NOT EXISTS #{prefix}.phoenix_kit_warehouse_transfers_number_seq")

    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix}.phoenix_kit_warehouse_transfers (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      number BIGINT NOT NULL DEFAULT nextval('#{prefix}.phoenix_kit_warehouse_transfers_number_seq'),
      status VARCHAR(20) NOT NULL DEFAULT 'draft',
      source_location_uuid UUID,
      destination_location_uuid UUID,
      note TEXT,
      storage_folder_uuid UUID,
      lines JSONB NOT NULL DEFAULT '[]'::jsonb,
      source_refs JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_by_uuid UUID,
      performed_by_uuid UUID REFERENCES #{prefix}.phoenix_kit_users(uuid) ON DELETE SET NULL,
      shipped_at TIMESTAMPTZ,
      received_at TIMESTAMPTZ,
      cancelled_at TIMESTAMPTZ,
      deleted_at TIMESTAMPTZ,
      deleted_by_uuid UUID,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_number_index
    ON #{prefix}.phoenix_kit_warehouse_transfers (number)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_status_index
    ON #{prefix}.phoenix_kit_warehouse_transfers (status)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_inserted_at_index
    ON #{prefix}.phoenix_kit_warehouse_transfers (inserted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_deleted_at_index
    ON #{prefix}.phoenix_kit_warehouse_transfers (deleted_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_source_location_uuid_index
    ON #{prefix}.phoenix_kit_warehouse_transfers (source_location_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_destination_location_uuid_index
    ON #{prefix}.phoenix_kit_warehouse_transfers (destination_location_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_shipped_at_index
    ON #{prefix}.phoenix_kit_warehouse_transfers (shipped_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_warehouse_transfers_received_at_index
    ON #{prefix}.phoenix_kit_warehouse_transfers (received_at)
    """)

    # Version marker lives on phoenix_kit_warehouse_stock — this module's own
    # table, guaranteed to exist by the time this runs — NOT on core's
    # `phoenix_kit` table, which is core's marker to manage exclusively.
    execute("COMMENT ON TABLE #{prefix}.phoenix_kit_warehouse_stock IS '1'")
  end

  def down(%{prefix: prefix}) do
    execute("DROP TABLE IF EXISTS #{prefix}.phoenix_kit_warehouse_transfers")
    execute("DROP SEQUENCE IF EXISTS #{prefix}.phoenix_kit_warehouse_transfers_number_seq")
    execute("COMMENT ON TABLE #{prefix}.phoenix_kit_warehouse_stock IS '0'")
  end
end
