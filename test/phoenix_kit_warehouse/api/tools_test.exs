defmodule PhoenixKitWarehouse.API.ToolsTest do
  @moduledoc """
  The tool declarations of the warehouse module, checked as core's executor
  sees them: scopes and permission, closed input schemas, the batch caps, the
  confirmation flow, and one success and one error per tool through
  `PhoenixKit.API.Executor`. The transport (REST / MCP) is core's.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  # Runs only against a core that has the API (see test_helper.exs).
  @moduletag :core_api

  import PhoenixKitWarehouse.Test.ApiFixtures
  import Plug.Conn

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Approvals
  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.Tool
  alias PhoenixKit.API.ToolLint
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  # Core's API is optional for this package: reached by name only.
  @compile {:no_warn_undefined,
            [
              PhoenixKit.API.Approvals,
              PhoenixKit.API.Auth,
              PhoenixKit.API.Executor,
              PhoenixKit.API.Keys,
              PhoenixKit.API.Keys.Cache,
              PhoenixKit.API.Registry,
              PhoenixKit.API.Tool,
              PhoenixKit.API.ToolLint,
              PhoenixKit.Cache,
              PhoenixKit.Cache.Registry,
              PhoenixKit.Users.Auth.Scope,
              PhoenixKit.Users.Permissions,
              PhoenixKit.Users.Roles
            ]}

  @registry_key {PhoenixKit, :registered_modules}

  @scopes %{
    "warehouse.list_locations" => "warehouse.stock:read",
    "warehouse.get_stock" => "warehouse.stock:read",
    "warehouse.receive_stock" => "warehouse.stock:receive",
    "warehouse.set_stock" => "warehouse.stock:adjust",
    "warehouse.issue_stock" => "warehouse.stock:issue"
  }

  setup do
    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :api_keys, ttl: :timer.seconds(60)})
    start_supervised!(PhoenixKit.API.Keys.Cache)

    # Core signs confirmation codes with the application's secret; this package
    # has no endpoint of its own to take one from.
    secret = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("c", 64))

    previous = :persistent_term.get(@registry_key, :unset)
    :persistent_term.put(@registry_key, [PhoenixKitWarehouse])
    admin_enabled = Settings.get_boolean_setting("api_admin_enabled", false)
    batch_over = Settings.get_setting("api_confirm_batch_over")

    on_exit(fn ->
      case previous do
        :unset -> :persistent_term.erase(@registry_key)
        modules -> :persistent_term.put(@registry_key, modules)
      end

      if secret,
        do: Application.put_env(:phoenix_kit, :secret_key_base, secret),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)

      Settings.update_boolean_setting("api_admin_enabled", admin_enabled)
      Settings.update_setting("api_confirm_batch_over", batch_over || "50")
    end)

    # The module is enabled and registered BEFORE the key is created: core only
    # offers scopes that an enabled module's tool declares.
    {:ok, _} = Settings.update_boolean_setting("api_admin_enabled", true)
    {:ok, _} = PhoenixKitWarehouse.enable_system()

    %{locations: [first | _]} = warehouses!(2)
    catalogue = shop_catalogue!()
    owner = owner_with(["warehouse"])

    %{
      first: first,
      catalogue: catalogue,
      a: item!(catalogue),
      b: item!(catalogue),
      user: owner
    }
  end

  # A real user whose role holds the `api` permission and `permissions`.
  defp owner_with(permissions) do
    {:ok, role} = Roles.create_role(%{name: "WhApi#{System.unique_integer([:positive])}"})
    for key <- ["api" | permissions], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = user!()
    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  # A key created by its owner with the owner's own scope, as the settings page does.
  defp issue_key(owner, scopes, attrs \\ %{}) do
    scope = Scope.for_user(owner, narrow: false)

    {:ok, key, token} =
      Keys.create_key(owner, scope, Map.merge(%{name: "wh api", scopes: scopes}, attrs))

    {key, token}
  end

  # A request from an address no other test uses (the rate-limit counters are shared).
  defp authed(token) do
    n = System.unique_integer([:positive])
    peer = {10, rem(n, 250) + 1, rem(div(n, 250), 250) + 1, rem(div(n, 62_500), 250) + 1}

    :post
    |> Plug.Test.conn("/")
    |> Map.put(:remote_ip, peer)
    |> put_req_header("authorization", "Bearer " <> token)
    |> Auth.call(Auth.init(audience: :admin))
  end

  # Runs a tool through core's real `Executor.call/4` with a key that holds
  # `scopes`. Answers `{status, decoded_body, key}`.
  defp call_tool(user, name, input, scopes \\ Map.values(@scopes)) do
    {key, token} = issue_key(user, scopes)
    {status, body} = call_with(token, name, input)
    {status, body, key}
  end

  defp call_with(token, name, input) do
    conn = Executor.call(authed(token), :admin, name, input)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  describe "the declarations" do
    test "five admin tools with their scopes and the warehouse permission" do
      tools = PhoenixKitWarehouse.api_tools()

      assert tools |> Enum.map(&{&1.name, &1.scope}) |> Enum.sort() ==
               Enum.sort(Map.to_list(@scopes))

      assert Enum.all?(tools, &(&1.audience == :admin and &1.permission == "warehouse"))
      assert Enum.all?(tools, &match?({:ok, _}, Tool.validate(&1)))
      assert Enum.all?(tools, &(is_binary(&1.description) and &1.description != ""))
    end

    test "read tools are read-only; write tools are not; issue and set are destructive" do
      by_name = Map.new(PhoenixKitWarehouse.api_tools(), &{&1.name, &1})

      for name <- ["warehouse.list_locations", "warehouse.get_stock"] do
        assert by_name[name].annotations.read_only
        assert by_name[name].annotations.idempotent
        refute by_name[name].annotations.destructive
      end

      for name <- ["warehouse.receive_stock", "warehouse.set_stock", "warehouse.issue_stock"] do
        refute by_name[name].annotations.read_only
        refute by_name[name].annotations.open_world
      end

      refute by_name["warehouse.receive_stock"].annotations.destructive
      assert by_name["warehouse.set_stock"].annotations.destructive
      assert by_name["warehouse.issue_stock"].annotations.destructive
    end

    test "every input schema is closed and its list limit equals the tool's max_items" do
      for tool <- PhoenixKitWarehouse.api_tools() do
        assert tool.input_schema["additionalProperties"] == false, tool.name
        assert tool.danger == nil, tool.name
      end

      by_name = Map.new(PhoenixKitWarehouse.api_tools(), &{&1.name, &1})

      for name <- ["warehouse.receive_stock", "warehouse.set_stock", "warehouse.issue_stock"] do
        assert by_name[name].max_items == 500
        assert by_name[name].input_schema["properties"]["lines"]["maxItems"] == 500
      end

      assert by_name["warehouse.get_stock"].max_items == 50
      assert by_name["warehouse.get_stock"].input_schema["properties"]["refs"]["maxItems"] == 50
      assert by_name["warehouse.list_locations"].max_items == nil
    end

    test "the write descriptions name the confirmation setting, not a number, and the retry refusal" do
      for tool <- PhoenixKitWarehouse.api_tools(), not tool.annotations.read_only do
        assert tool.description =~ "api_confirm_batch_over", tool.name
        refute tool.description =~ ~r/\b50 lines/, tool.name

        assert tool.description =~ "its ref must match a stored identity", tool.name

        assert tool.description =~ "external_ref_lines_unverified", tool.name
      end
    end

    test "issue_stock requires reason and lines; receive_stock has unit_value on lines and no source" do
      by_name = Map.new(PhoenixKitWarehouse.api_tools(), &{&1.name, &1})

      assert Enum.sort(by_name["warehouse.issue_stock"].input_schema["required"]) == [
               "lines",
               "reason"
             ]

      assert by_name["warehouse.issue_stock"].input_schema["properties"]["reason"]["enum"]
             |> Enum.sort() ==
               ["damage", "other", "production", "sale"]

      assert Map.has_key?(
               by_name["warehouse.issue_stock"].input_schema["properties"],
               "external_ref"
             )

      receive_props = by_name["warehouse.receive_stock"].input_schema["properties"]
      assert Map.has_key?(receive_props["lines"]["items"]["properties"], "unit_value")
      refute Map.has_key?(receive_props, "source")

      refute Map.has_key?(
               by_name["warehouse.set_stock"].input_schema["properties"]["lines"]["items"][
                 "properties"
               ],
               "unit_value"
             )
    end

    test "the tool texts say what an agent must know: the catalogue_id rule and the retry handle" do
      by_name = Map.new(PhoenixKitWarehouse.api_tools(), &{&1.name, &1})

      for name <- ["warehouse.receive_stock", "warehouse.set_stock", "warehouse.issue_stock"] do
        assert by_name[name].description =~ "external_ref", name
        assert by_name[name].description =~ "confirm_token", name
      end

      issue_props = by_name["warehouse.issue_stock"].input_schema["properties"]
      assert issue_props["external_ref"]["description"] =~ "skipped"
      assert issue_props["source"]["description"] =~ "external_ref"

      for name <- [
            "warehouse.get_stock",
            "warehouse.receive_stock",
            "warehouse.set_stock",
            "warehouse.issue_stock"
          ] do
        description = by_name[name].input_schema["properties"]["catalogue_id"]["description"]
        assert description =~ "more than one active catalogue", name
      end
    end
  end

  describe "the confirmation gate" do
    test "without core's confirmation flow only the read tools are offered" do
      names = fn tools -> tools |> Enum.map(& &1.name) |> Enum.sort() end

      assert names.(PhoenixKitWarehouse.API.tools([])) ==
               ["warehouse.get_stock", "warehouse.list_locations"]

      assert names.(PhoenixKitWarehouse.API.tools([{Enum, :no_such_function, 1}])) ==
               ["warehouse.get_stock", "warehouse.list_locations"]

      assert length(PhoenixKitWarehouse.API.tools()) == 5
      assert PhoenixKitWarehouse.API.confirmation_available?()
    end
  end

  describe "the registry" do
    test "collects the tools of the enabled module, tagged with it, and answers module_disabled when it is off" do
      names = PhoenixKit.ModuleRegistry.all_api_tools() |> Enum.map(& &1.name)
      assert Enum.all?(Map.keys(@scopes), &(&1 in names))

      assert {:ok, %{module: PhoenixKitWarehouse, name: "warehouse.get_stock"}} =
               Registry.find("warehouse.get_stock", :admin)

      {:ok, _} = PhoenixKitWarehouse.disable_system()
      assert {:error, :module_disabled} = Registry.find("warehouse.get_stock", :admin)
    end
  end

  describe "through the executor (one success and one error per tool)" do
    test "warehouse.list_locations", %{first: first, user: user} do
      assert {200,
              %{"locations" => locations, "default_location_id" => default, "setup" => "ready"},
              _} =
               call_tool(user, "warehouse.list_locations", %{})

      assert default == first.uuid and length(locations) == 2

      assert {422, %{"code" => "validation_failed"}, _} =
               call_tool(user, "warehouse.list_locations", %{"location_id" => first.uuid})
    end

    test "warehouse.get_stock", %{first: first, a: a, user: user} do
      seed!(a.uuid, "4", first.uuid)

      assert {200, %{"results" => [%{"total" => "4", "id" => id}]}, _} =
               call_tool(user, "warehouse.get_stock", %{"refs" => [%{"id" => a.uuid}]})

      assert id == a.uuid

      assert {422,
              %{"code" => "validation_failed", "context" => %{"errors" => [%{"path" => path}]}},
              _} =
               call_tool(user, "warehouse.get_stock", %{"refs" => []})

      assert path =~ "refs"
    end

    test "warehouse.receive_stock, and the two Activity entries it leaves", %{
      first: first,
      a: a,
      user: user
    } do
      input = %{
        "external_ref" => "EXE-1",
        "lines" => [%{"ref" => %{"id" => a.uuid}, "quantity" => "3"}]
      }

      assert {200,
              %{
                "status" => "posted",
                "results" => [%{"from" => "0", "to" => "3"}],
                "document" => document
              }, key} =
               call_tool(user, "warehouse.receive_stock", input)

      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(3))

      # Core's request-level entry and this module's domain entry.
      assert Repo.one(
               from(e in Entry, where: e.action == "api.request" and e.resource_uuid == ^key.uuid)
             )

      assert Repo.one(
               from(e in Entry,
                 where:
                   e.action == "warehouse.goods_receipt.posted" and
                     e.resource_uuid == ^document["id"]
               )
             )

      assert {422,
              %{
                "code" => "validation_failed",
                "context" => %{
                  "errors" => [%{"path" => "lines[0].ref", "code" => "not_found"}],
                  "posted" => false
                }
              }, _} =
               call_tool(user, "warehouse.receive_stock", %{
                 "lines" => [%{"ref" => %{"id" => Ecto.UUID.generate()}, "quantity" => "1"}]
               })
    end

    test "warehouse.set_stock", %{first: first, a: a, user: user} do
      seed!(a.uuid, "9", first.uuid)

      assert {200, %{"results" => [%{"from" => "9", "to" => "2"}]}, _} =
               call_tool(user, "warehouse.set_stock", %{
                 "lines" => [%{"ref" => %{"id" => a.uuid}, "quantity" => 2}]
               })

      assert {422, %{"context" => %{"errors" => [%{"path" => "lines[0].quantity"}]}}, _} =
               call_tool(user, "warehouse.set_stock", %{
                 "lines" => [%{"ref" => %{"id" => a.uuid}, "quantity" => "-1"}]
               })
    end

    test "warehouse.issue_stock: success, and insufficient_stock lists every short line", %{
      first: first,
      a: a,
      b: b,
      user: user
    } do
      seed!(a.uuid, "5", first.uuid)

      assert {200, %{"results" => [%{"from" => "5", "to" => "3"}]}, _} =
               call_tool(user, "warehouse.issue_stock", %{
                 "reason" => "sale",
                 "lines" => [%{"ref" => %{"id" => a.uuid}, "quantity" => "2"}]
               })

      lines = [
        %{"ref" => %{"id" => a.uuid}, "quantity" => "9"},
        %{"ref" => %{"id" => b.uuid}, "quantity" => "1"}
      ]

      assert {422,
              %{
                "code" => "insufficient_stock",
                "context" => %{"lines" => short, "posted" => false}
              }, _} =
               call_tool(user, "warehouse.issue_stock", %{"reason" => "sale", "lines" => lines})

      assert Enum.sort(Enum.map(short, & &1["id"])) == Enum.sort([a.uuid, b.uuid])
      assert Enum.all?(short, &(is_binary(&1["requested"]) and is_binary(&1["available"])))
    end
  end

  describe "rights and limits are the executor's, and they hold for these tools" do
    test "a key without the scope is refused with 403 and nothing is posted", %{
      first: first,
      a: a,
      user: user
    } do
      input = %{"lines" => [%{"ref" => %{"id" => a.uuid}, "quantity" => "1"}]}

      assert {403,
              %{
                "code" => "forbidden",
                "context" => %{"required_scope" => "warehouse.stock:receive"}
              }, _} =
               call_tool(user, "warehouse.receive_stock", input, ["warehouse.stock:read"])

      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(0))
    end

    test "more than 500 lines is refused before the handler runs", %{a: a, user: user} do
      lines = List.duplicate(%{"ref" => %{"id" => a.uuid}, "quantity" => "1"}, 501)

      assert {422,
              %{
                "code" => "validation_failed",
                "context" => %{"errors" => [%{"path" => "lines", "limit" => 500}]}
              }, _} =
               call_tool(user, "warehouse.receive_stock", %{"lines" => lines})
    end

    test "a write above core's row threshold is held for confirmation; the code posts it once", %{
      catalogue: catalogue,
      first: first,
      user: user
    } do
      {:ok, _} = Settings.update_setting("api_confirm_batch_over", "2")

      items = for _ <- 1..3, do: item!(catalogue)
      lines = for item <- items, do: %{"ref" => %{"id" => item.uuid}, "quantity" => "1"}
      input = %{"lines" => lines}
      {_key, token} = issue_key(user, Map.values(@scopes))
      documents_before = Repo.aggregate(PhoenixKitWarehouse.InventoryDocument, :count)

      # The first call changes nothing: it answers a preview and a code.
      assert {200,
              %{"executed" => false, "status" => "confirmation_required", "confirm_token" => code}} =
               call_with(token, "warehouse.set_stock", input)

      assert is_binary(code)
      assert Repo.aggregate(PhoenixKitWarehouse.InventoryDocument, :count) == documents_before

      # The same call with the code posts.
      assert {200, %{"status" => "posted", "summary" => %{"updated" => 3}}} =
               call_with(token, "warehouse.set_stock", Map.put(input, "confirm_token", code))

      for item <- items,
          do: assert(Decimal.equal?(quantity(item.uuid, first.uuid), Decimal.new(1)))

      assert Repo.aggregate(PhoenixKitWarehouse.InventoryDocument, :count) == documents_before + 1

      # A spent code is refused.
      assert {409, %{"context" => %{"reason" => "used"}}} =
               call_with(token, "warehouse.set_stock", Map.put(input, "confirm_token", code))

      assert Repo.aggregate(PhoenixKitWarehouse.InventoryDocument, :count) == documents_before + 1
    end

    test "a code is refused when the stock moved after the preview", %{
      catalogue: catalogue,
      first: first,
      user: user
    } do
      {:ok, _} = Settings.update_setting("api_confirm_batch_over", "2")

      items = for _ <- 1..3, do: item!(catalogue)

      input = %{
        "lines" => for(item <- items, do: %{"ref" => %{"id" => item.uuid}, "quantity" => "1"})
      }

      {_key, token} = issue_key(user, Map.values(@scopes))

      assert {200, %{"confirm_token" => code}} = call_with(token, "warehouse.set_stock", input)

      seed!(hd(items).uuid, "7", first.uuid)

      assert {409, %{"context" => %{"reason" => "changed"}}} =
               call_with(token, "warehouse.set_stock", Map.put(input, "confirm_token", code))

      assert Decimal.equal?(quantity(hd(items).uuid, first.uuid), Decimal.new(7))
    end

    test "exactly the threshold is not held", %{catalogue: catalogue, user: user} do
      {:ok, _} = Settings.update_setting("api_confirm_batch_over", "2")
      lines = for _ <- 1..2, do: %{"ref" => %{"id" => item!(catalogue).uuid}, "quantity" => "1"}

      assert {200, %{"status" => "posted"}, _} =
               call_tool(user, "warehouse.set_stock", %{"lines" => lines})
    end

    test "dry_run through the executor answers the preview and writes nothing", %{
      first: first,
      a: a,
      user: user
    } do
      input = %{
        "dry_run" => true,
        "external_ref" => "DRY-1",
        "lines" => [%{"ref" => %{"id" => a.uuid}, "quantity" => "3"}]
      }

      assert {200,
              %{
                "executed" => false,
                "dry_run" => true,
                "preview" => %{
                  "status" => "would_post",
                  "results" => [%{"from" => "0", "to" => "3"}]
                }
              }, _} =
               call_tool(user, "warehouse.receive_stock", input)

      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(0))
    end

    test "a read tool refuses dry_run", %{user: user} do
      assert {422, %{"code" => "validation_failed"}, _} =
               call_tool(user, "warehouse.list_locations", %{"dry_run" => true})
    end

    test "the tools pass core's tool lint" do
      assert :ok = ToolLint.check_tools(PhoenixKitWarehouse.api_tools())
    end

    test "a key that needs approval is held; the approver's decision posts and is logged with the approver",
         %{
           first: first,
           a: a,
           b: b,
           user: user
         } do
      # Approval is asked for what is dangerous: here, more rows than the threshold.
      {:ok, _} = Settings.update_setting("api_confirm_batch_over", "1")
      {_key, token} = issue_key(user, Map.values(@scopes), %{requires_approval: true})

      input = %{
        "external_ref" => "APPR-1",
        "lines" => [
          %{"ref" => %{"id" => a.uuid}, "quantity" => "4"},
          %{"ref" => %{"id" => b.uuid}, "quantity" => "1"}
        ]
      }

      assert {200, %{"executed" => false, "status" => "pending_approval", "approval_id" => id}} =
               call_with(token, "warehouse.receive_stock", input)

      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(0))

      # The key's creator, who holds the tool's permission, may decide.
      approver = user

      assert {:ok, %{status: "executed"}} =
               Approvals.approve(id, Scope.for_user(approver, narrow: false))

      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(4))
      assert Decimal.equal?(quantity(b.uuid, first.uuid), Decimal.new(1))

      entry = Repo.one!(from(e in Entry, where: e.action == "warehouse.goods_receipt.posted"))
      assert entry.metadata["approved_by_uuid"] == approver.uuid
      assert entry.metadata["via"] == "api"
    end

    test "schema refusals have no row code; what the schema lets through gets a row error", %{
      a: a,
      user: user
    } do
      ref = %{"id" => a.uuid}

      for quantity <- [true, nil, [1], %{}] do
        assert {422, %{"code" => "validation_failed", "context" => %{"errors" => [error]}}, _} =
                 call_tool(user, "warehouse.receive_stock", %{
                   "lines" => [%{"ref" => ref, "quantity" => quantity}]
                 })

        assert error["path"] == "lines[0].quantity"
        refute Map.has_key?(error, "code")
      end

      assert {422, %{"context" => %{"errors" => [%{"path" => "lines"}]}}, _} =
               call_tool(user, "warehouse.receive_stock", %{"lines" => []})

      assert {422, %{"context" => %{"errors" => [%{"path" => "external_ref"}]}}, _} =
               call_tool(user, "warehouse.receive_stock", %{
                 "external_ref" => String.duplicate("x", 256),
                 "lines" => [%{"ref" => ref, "quantity" => "1"}]
               })

      # The schema lets these through: the handler answers row errors with a code.
      for quantity <- ["-1", "1,5", "1e3", "1.0000001"] do
        assert {422,
                %{
                  "context" => %{
                    "errors" => [%{"path" => "lines[0].quantity", "code" => "validation_failed"}],
                    "posted" => false
                  }
                }, _} =
                 call_tool(user, "warehouse.receive_stock", %{
                   "lines" => [%{"ref" => ref, "quantity" => quantity}]
                 })
      end

      assert {422,
              %{
                "context" => %{
                  "errors" => [%{"path" => "external_ref", "code" => "validation_failed"}]
                }
              }, _} =
               call_tool(user, "warehouse.receive_stock", %{
                 "external_ref" => "   ",
                 "lines" => [%{"ref" => ref, "quantity" => "1"}]
               })
    end

    test "issue_stock takes an external_ref: a retry is skipped; beside an external source it is refused",
         %{first: first, a: a, user: user} do
      seed!(a.uuid, "10", first.uuid)

      input = %{
        "reason" => "sale",
        "external_ref" => "ISSUE-EXE-1",
        "lines" => [%{"ref" => %{"id" => a.uuid}, "quantity" => "3"}]
      }

      assert {200, %{"status" => "posted", "document" => %{"external_ref" => "ISSUE-EXE-1"}}, _} =
               call_tool(user, "warehouse.issue_stock", input)

      assert {200, %{"status" => "skipped"}, _} = call_tool(user, "warehouse.issue_stock", input)
      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(7))

      both = Map.put(input, "source", %{"kind" => "external", "ref" => "OTHER-1"})

      assert {422,
              %{
                "context" => %{
                  "errors" => [%{"path" => "external_ref", "code" => "validation_failed"}]
                }
              }, _} = call_tool(user, "warehouse.issue_stock", both)

      assert Decimal.equal?(quantity(a.uuid, first.uuid), Decimal.new(7))
    end

    test "an unknown field is refused (the schemas are closed)", %{a: a, user: user} do
      assert {422, %{"code" => "validation_failed"}, _} =
               call_tool(user, "warehouse.receive_stock", %{
                 "lines" => [%{"ref" => %{"id" => a.uuid}, "quantity" => "1", "price" => "9"}]
               })
    end
  end
end
