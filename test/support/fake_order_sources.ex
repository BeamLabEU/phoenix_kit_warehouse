defmodule PhoenixKitWarehouse.Test.FakeOrderSources do
  @moduledoc """
  Fake `"order"`/`"sub_order"` source_kinds callbacks for tests that used to
  build real `Andi.Orders`/`Andi.SubOrders` fixtures. Register via:

      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [
        PhoenixKitWarehouse.Test.FakeOrderSources.order_kind(),
        PhoenixKitWarehouse.Test.FakeOrderSources.sub_order_kind()
      ])

  Backed by a bare `Agent` so a test can seed fake "orders"/"sub-orders" as
  plain maps and have `search`/`resolve`/`build_lines` see them — no real
  `Andi.Orders`/`Andi.SubOrders` schema or table involved.
  """

  use Agent

  def start_link(_opts \\ []),
    do: Agent.start_link(fn -> %{orders: %{}, sub_orders: %{}} end, name: __MODULE__)

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end
  end

  @doc "Registers a fake top-level order: `%{uuid:, label:, lines: [%{\"item_uuid\" => ..., \"required_quantity\" => ...}]}`."
  def put_order(order) do
    ensure_started()
    Agent.update(__MODULE__, &put_in(&1, [:orders, order.uuid], order))
    order
  end

  @doc "Registers a fake sub-order: `%{uuid:, label:, lines: [...]}`."
  def put_sub_order(sub_order) do
    ensure_started()
    Agent.update(__MODULE__, &put_in(&1, [:sub_orders, sub_order.uuid], sub_order))
    sub_order
  end

  def order_kind do
    %{
      kind: "order",
      label: "Order",
      search: {__MODULE__, :search_orders, []},
      resolve: {__MODULE__, :resolve_order, []},
      build_lines: {__MODULE__, :build_order_lines, []}
    }
  end

  def sub_order_kind do
    %{
      kind: "sub_order",
      label: "Sub-order",
      search: {__MODULE__, :search_sub_orders, []},
      resolve: {__MODULE__, :resolve_sub_order, []},
      build_lines: {__MODULE__, :build_sub_order_lines, []}
    }
  end

  def search_orders(query), do: search(:orders, query)
  def search_sub_orders(query), do: search(:sub_orders, query)

  defp search(bucket, query) do
    ensure_started()

    Agent.get(__MODULE__, & &1)
    |> Map.fetch!(bucket)
    |> Map.values()
    |> Enum.filter(&(query == "" or String.contains?(&1.label, query)))
    |> Enum.map(&%{uuid: &1.uuid, label: &1.label, extra: %{}})
  end

  def resolve_order(uuid), do: resolve(:orders, uuid)
  def resolve_sub_order(uuid), do: resolve(:sub_orders, uuid)

  defp resolve(bucket, uuid) do
    ensure_started()

    case Agent.get(__MODULE__, & &1) |> Map.fetch!(bucket) |> Map.get(uuid) do
      nil -> :error
      order -> %{label: order.label, path: "/fake/#{bucket}/#{uuid}"}
    end
  end

  def build_order_lines(uuid, _actor_uuid), do: build_lines(:orders, uuid)
  def build_sub_order_lines(uuid, _actor_uuid), do: build_lines(:sub_orders, uuid)

  defp build_lines(bucket, uuid) do
    ensure_started()

    case Agent.get(__MODULE__, & &1) |> Map.fetch!(bucket) |> Map.get(uuid) do
      nil -> :error
      order -> {:ok, order.lines}
    end
  end
end
