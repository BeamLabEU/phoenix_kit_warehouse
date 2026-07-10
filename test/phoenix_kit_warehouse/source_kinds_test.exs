defmodule PhoenixKitWarehouse.SourceKindsTest do
  use ExUnit.Case, async: false

  alias PhoenixKitWarehouse.SourceKinds
  alias PhoenixKitWarehouse.Test.FakeSourceKind

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_warehouse, :source_kinds) end)
  end

  describe "with zero kinds configured (standalone)" do
    test "search_candidates/1 returns []" do
      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [])
      assert SourceKinds.search_candidates("anything") == []
    end

    test "resolve/2 returns :error" do
      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [])
      assert SourceKinds.resolve("widget", "widget-1") == :error
    end

    test "build_lines/3 returns {:error, :unsupported_kind}" do
      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [])

      assert SourceKinds.build_lines("widget", "widget-1", "actor-1") ==
               {:error, :unsupported_kind}
    end
  end

  describe "with one configured kind" do
    setup do
      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
        %{
          kind: "widget",
          label: "Widget",
          search: {FakeSourceKind, :search, []},
          resolve: {FakeSourceKind, :resolve, []},
          build_lines: {FakeSourceKind, :build_lines, []}
        }
      ])

      :ok
    end

    test "search_candidates/1 happy path" do
      assert [
               %{
                 kind: "widget",
                 label_prefix: "Widget",
                 uuid: "widget-1",
                 label: label,
                 extra: extra
               }
             ] =
               SourceKinds.search_candidates("query")

      assert label == "Widget matching query"
      assert extra == %{sku: "W-1"}
    end

    test "resolve/2 happy path" do
      assert SourceKinds.resolve("widget", "widget-1") == %{
               label: "Widget One",
               path: "/widgets/widget-1"
             }
    end

    test "resolve/2 returns :error for an unknown uuid within a known kind" do
      assert SourceKinds.resolve("widget", "nope") == :error
    end

    test "build_lines/3 happy path" do
      assert SourceKinds.build_lines("widget", "widget-1", "actor-1") ==
               {:ok, [%{item_uuid: "item-1", name: "Widget", quantity: 3}]}
    end

    test "resolve/2 for an unregistered kind returns :error" do
      assert SourceKinds.resolve("unregistered_kind", "widget-1") == :error
    end
  end

  describe "graceful degradation" do
    test "resolve/2 returns :error when the callback itself raises" do
      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
        %{
          kind: "widget",
          label: "Widget",
          search: {FakeSourceKind, :search, []},
          resolve: {FakeSourceKind, :resolve_raises, []}
        }
      ])

      assert SourceKinds.resolve("widget", "widget-1") == :error
    end

    test "build_lines/3 returns {:error, :unsupported_kind} for a kind with no build_lines callback declared" do
      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
        %{
          kind: "widget",
          label: "Widget",
          search: {FakeSourceKind, :search, []},
          resolve: {FakeSourceKind, :resolve, []}
        }
      ])

      assert SourceKinds.build_lines("widget", "widget-1", "actor-1") ==
               {:error, :unsupported_kind}
    end
  end
end
