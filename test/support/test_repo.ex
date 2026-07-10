defmodule PhoenixKitWarehouse.Test.Repo do
  use Ecto.Repo,
    otp_app: :phoenix_kit_warehouse,
    adapter: Ecto.Adapters.Postgres
end
