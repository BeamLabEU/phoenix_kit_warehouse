defmodule PhoenixKitWarehouse.Test.FakeSourceKind do
  @moduledoc "Fake host callbacks for SourceKinds tests — deliberately not order/sub_order-shaped, to keep the test host-agnostic."

  def search(query) do
    [%{uuid: "widget-1", label: "Widget matching #{query}", extra: %{sku: "W-1"}}]
  end

  def resolve("widget-1"), do: %{label: "Widget One", path: "/widgets/widget-1"}
  def resolve(_), do: :error

  def resolve_raises(_uuid), do: raise("boom")

  def build_lines("widget-1", _actor_uuid) do
    {:ok, [%{item_uuid: "item-1", name: "Widget", quantity: 3}]}
  end

  def build_lines(_uuid, _actor_uuid), do: :error
end
