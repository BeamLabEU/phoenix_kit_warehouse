defmodule PhoenixKitWarehouse.Test.Endpoint do
  @moduledoc """
  Minimal Phoenix.Endpoint used by the LiveView test suite.

  `phoenix_kit_warehouse` is a library — in production it borrows the host
  app's endpoint and router (via `phoenix_kit_routes()`). For tests we spin
  up a tiny endpoint + router (`PhoenixKitWarehouse.Test.Router`) so
  `Phoenix.LiveViewTest` can drive our LiveViews through `live/2` with real
  URLs, at the exact same `/admin/andi/warehouse/...` paths `admin_tabs/0`
  serves in production.
  """

  use Phoenix.Endpoint, otp_app: :phoenix_kit_warehouse

  @session_options [
    store: :cookie,
    key: "_phoenix_kit_warehouse_test_key",
    signing_salt: "warehouse-test-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(PhoenixKitWarehouse.Test.Router)
end
