defmodule PhoenixKitWarehouse.SourceKindsModulesTest do
  @moduledoc """
  Source kinds declared by registered PhoenixKit modules
  (`warehouse_source_kinds/0`), merged with the host's `:source_kinds` list.
  """

  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.DocRefs
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.SourceKinds

  @registry_key {PhoenixKit, :registered_modules}

  defmodule Callbacks do
    @moduledoc false
    def search(query), do: [%{uuid: "decl-1", label: "Declared #{query}"}]
    def resolve("decl-1"), do: %{label: "Declared One", path: "/declared/decl-1"}
    def resolve(_), do: :error
    def build_lines("decl-1", _actor), do: {:ok, [%{"item_uuid" => "x"}]}
  end

  defmodule ShopModule do
    @moduledoc false
    def warehouse_source_kinds do
      [
        %{
          kind: "shop_order",
          label: "Shop order",
          search: {Callbacks, :search, []},
          resolve: {Callbacks, :resolve, []},
          build_lines: {Callbacks, :build_lines, []}
        }
      ]
    end
  end

  defmodule SecondModule do
    @moduledoc false
    def warehouse_source_kinds do
      [
        %{
          kind: "shop_order",
          label: "Second module's claim on shop_order",
          search: {Callbacks, :search, []},
          resolve: {Callbacks, :resolve, []}
        },
        %{
          kind: "pos_sale",
          label: "POS sale",
          search: {Callbacks, :search, []},
          resolve: {Callbacks, :resolve, []}
        }
      ]
    end
  end

  defmodule RaisingModule do
    @moduledoc false
    def warehouse_source_kinds, do: raise("boom")
  end

  defmodule GarbageModule do
    @moduledoc false
    def warehouse_source_kinds, do: [:not_a_map, %{label: "no kind key"}, nil]
  end

  defmodule MixedModule do
    @moduledoc false
    def warehouse_source_kinds do
      [
        %{
          kind: "pos_sale",
          label: "POS sale",
          search: {Callbacks, :search, []},
          resolve: {Callbacks, :resolve, []}
        },
        %{kind: :not_a_string}
      ]
    end
  end

  defmodule PlainModule do
    @moduledoc false
    def enabled?, do: true
  end

  setup do
    previous = :persistent_term.get(@registry_key, :unset)
    reset_warned()

    on_exit(fn ->
      case previous do
        :unset -> :persistent_term.erase(@registry_key)
        modules -> :persistent_term.put(@registry_key, modules)
      end

      Application.delete_env(:phoenix_kit_warehouse, :source_kinds)
      reset_warned()
    end)

    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [])
    :ok
  end

  defp reset_warned do
    for {{SourceKinds, :warned, _key} = flag, _} <- :persistent_term.get() do
      :persistent_term.erase(flag)
    end
  end

  defp register(modules), do: :persistent_term.put(@registry_key, modules)

  defp host_kind(kind, label) do
    %{
      kind: kind,
      label: label,
      search: {Callbacks, :search, []},
      resolve: {Callbacks, :resolve, []}
    }
  end

  defp kinds, do: Enum.map(SourceKinds.list_kinds(), &{&1.kind, &1.label})

  test "a module-declared kind shows up with no host configuration at all" do
    register([ShopModule])

    assert kinds() == [{"shop_order", "Shop order"}]
  end

  test "host kinds come first, module kinds are appended" do
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [host_kind("widget", "Widget")])
    register([ShopModule])

    assert kinds() == [{"widget", "Widget"}, {"shop_order", "Shop order"}]
  end

  test "on a conflict the host's definition wins, so a host can override a module's kind" do
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
      host_kind("shop_order", "Host's shop order")
    ])

    register([ShopModule])

    assert kinds() == [{"shop_order", "Host's shop order"}]
  end

  test "two modules declaring the same kind: one entry, the first registered module wins" do
    register([ShopModule, SecondModule])

    assert kinds() == [{"shop_order", "Shop order"}, {"pos_sale", "POS sale"}]
  end

  test "a module that raises, returns garbage, or does not export the callback is skipped" do
    register([RaisingModule, GarbageModule, PlainModule, ShopModule, Module.concat(NotLoaded, X)])

    assert kinds() == [{"shop_order", "Shop order"}]
  end

  test "entries that are not kind maps are dropped and logged, the valid ones kept" do
    register([GarbageModule, MixedModule])

    log = ExUnit.CaptureLog.capture_log(fn -> assert kinds() == [{"pos_sale", "POS sale"}] end)

    assert log =~ "GarbageModule"
    assert log =~ "3 entries"
    assert log =~ "MixedModule"
    assert log =~ "1 entry"
  end

  test "a module that stays broken is logged once, not on every call" do
    register([RaisingModule, GarbageModule])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..5, do: SourceKinds.list_kinds()
      end)

    assert length(String.split(log, "RaisingModule.warehouse_source_kinds/0 raised")) == 2
    assert length(String.split(log, "GarbageModule.warehouse_source_kinds/0 returned")) == 2
  end

  test "the registry key the tests write is the one core reads" do
    register([ShopModule])

    assert ShopModule in PhoenixKit.ModuleRegistry.all_modules()
  end

  test "the host list is untouched when the registry is empty" do
    Application.put_env(:phoenix_kit_warehouse, :source_kinds, [host_kind("widget", "Widget")])
    register([])

    assert kinds() == [{"widget", "Widget"}]
  end

  test "search, resolve and build_lines dispatch to a module-declared kind" do
    register([ShopModule])

    assert [%{kind: "shop_order", label_prefix: "Shop order", uuid: "decl-1"}] =
             SourceKinds.search_candidates("q")

    assert %{label: "Declared One", path: "/declared/decl-1"} =
             SourceKinds.resolve("shop_order", "decl-1")

    assert {:ok, [%{"item_uuid" => "x"}]} = SourceKinds.build_lines("shop_order", "decl-1", "a")
  end

  test "a module-declared kind is a valid goods-issue source ref, stored as \"type\", and renders" do
    register([ShopModule])

    {:ok, issue} = GoodsIssues.create_goods_issue(%{location_uuid: Ecto.UUID.generate()})

    assert {:ok, updated} = GoodsIssues.add_source_ref(issue, "shop_order", "decl-1")
    assert updated.source_refs == [%{"type" => "shop_order", "uuid" => "decl-1"}]

    assert [%{label: "Declared One", path: "/declared/decl-1"}] =
             DocRefs.refs_for(updated.source_refs)
  end

  test "without the declaring module the same kind is refused" do
    register([])

    {:ok, issue} = GoodsIssues.create_goods_issue(%{location_uuid: Ecto.UUID.generate()})

    assert {:error, :invalid_ref_type} = GoodsIssues.add_source_ref(issue, "shop_order", "decl-1")
  end
end
