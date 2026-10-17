defmodule PhoenixKitWarehouse.Test.ApiOrders do
  @moduledoc false
  # Stand-in for the callbacks the E-commerce module registers for the
  # "shop_order" source kind. `resolve/1` answers for the orders a test has
  # registered.

  def put(uuid, label), do: :persistent_term.put({__MODULE__, uuid}, label)

  def search(_query), do: []

  def resolve(uuid) do
    case :persistent_term.get({__MODULE__, uuid}, nil) do
      nil ->
        :error

      label ->
        %{label: label, path: "/admin/orders/#{uuid}"}
    end
  end

  def kind do
    %{
      kind: "shop_order",
      label: "Shop order",
      search: {__MODULE__, :search, []},
      resolve: {__MODULE__, :resolve, []}
    }
  end
end
