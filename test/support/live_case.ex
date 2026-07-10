defmodule PhoenixKitWarehouse.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection. Tests using this case are tagged `:integration` and get
  excluded when the test DB isn't available, matching the rest of the
  suite (`PhoenixKitWarehouse.DataCase`'s convention).

  Unlike `PhoenixKitCatalogue.LiveCase`, this case does **not** short-circuit
  authentication with a fake scope — every ported warehouse LiveView reads
  `phoenix_kit_current_scope` (not just `phoenix_kit_current_user`) and
  calls `PhoenixKit.Users.Auth.Scope.admin?/1`, so tests use the real
  register/confirm/promote/login flow via `PhoenixKit.Users.Auth`, exactly
  as the original Andi tests did — this module only provides the
  Endpoint/sandbox plumbing, not a login shortcut.

  ## Example

      defmodule PhoenixKitWarehouse.Web.StockLiveTest do
        use PhoenixKitWarehouse.LiveCase

        test "renders", %{conn: conn} do
          {:ok, view, html} = live(conn, "/en/admin/warehouse")
          assert html =~ "In stock"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitWarehouse.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitWarehouse.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end
end
