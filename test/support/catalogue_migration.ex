defmodule PhoenixKitWarehouse.Test.CatalogueMigration do
  @moduledoc """
  Test-boot wrapper around `phoenix_kit_catalogue`'s own module-owned
  migration chain (the `phoenix_kit_document_creator` precedent, mirrored by
  `phoenix_kit_crm`'s `PhoenixKitCRM.Test.SchemaMigration`): `test_helper.exs`
  runs this through `Ecto.Migrator`, keyed on `migrator_version/0`, so a
  chain bump re-applies automatically. `execute/1` inside
  `PhoenixKitCatalogue.Migrations` requires a live migration runner
  process — this wrapper is how the test suite provides one outside of
  `mix phoenix_kit.update`. Without it, `phoenix_kit_cat_items` never gets
  V2's per-language `slug` column and every catalogue item insert in this
  suite fails with `column "slug" ... does not exist`.
  """

  use Ecto.Migration

  alias PhoenixKitCatalogue.Migrations

  # `schema_migrations` is one physical table every module-owned migration
  # chain's `Ecto.Migrator.run` call writes into on this repo.
  # `Migrations.current_version/0` is a small integer (1, 2, ...) private to
  # THIS chain's own `pkc_schema:N` marker convention — reusing it as the
  # Migrator's bookkeeping version risks colliding with unrelated chains
  # (core's own `ensure_current/2` sidesteps this by keying on a
  # microsecond timestamp instead). This offset keeps the Migrator record
  # in a band no other package's version numbers land in.
  @spec migrator_version() :: pos_integer()
  def migrator_version, do: 979_797_971_000_000 + Migrations.current_version()

  def up, do: Migrations.up(prefix: "public")
  def down, do: Migrations.down(prefix: "public")
end
