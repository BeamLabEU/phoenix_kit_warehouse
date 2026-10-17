defmodule PhoenixKitWarehouse.Test.ApiOrderModule do
  @moduledoc false
  # Stand-in for the E-commerce module as the warehouse sees it: a registered
  # module that declares the "shop_order" kind through
  # `warehouse_source_kinds/0` and that can be switched off, like a module
  # that is installed but disabled.

  alias PhoenixKitWarehouse.Test.ApiOrders

  def enable(value), do: :persistent_term.put({__MODULE__, :enabled}, value)
  def reset, do: :persistent_term.erase({__MODULE__, :enabled})

  def enabled?, do: :persistent_term.get({__MODULE__, :enabled}, true)

  def warehouse_source_kinds, do: [ApiOrders.kind()]
end
