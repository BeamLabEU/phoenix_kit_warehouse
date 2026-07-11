defmodule PhoenixKitWarehouse.Test.MigrationsRunner do
  @moduledoc """
  0-arity `Ecto.Migration` wrapper used by
  `PhoenixKitWarehouse.Migrations.PostgresTest` to exercise
  `PhoenixKitWarehouse.Migrations.Postgres.up/1` and `down/1` through a
  real `Ecto.Migration.Runner` context — the `execute/1` calls inside
  `Postgres.V01` only work while such a context is active (set up by
  `Ecto.Migrator`, which requires the migration module it drives to expose
  `up/0` / `down/0`). Mirrors `PhoenixKit.Migration.Runner`.
  """

  use Ecto.Migration

  alias PhoenixKitWarehouse.Migrations.Postgres

  def up, do: Postgres.up(prefix: "public", version: Postgres.current_version())
  def down, do: Postgres.down(prefix: "public", version: 0)
end
