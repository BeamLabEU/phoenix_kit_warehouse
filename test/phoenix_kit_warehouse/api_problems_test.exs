defmodule PhoenixKitWarehouse.ApiProblemsTest do
  use ExUnit.Case, async: true

  test "the module declares insufficient_stock, which core no longer answers for it" do
    assert %{insufficient_stock: %{status: 422, title: "Insufficient stock", advice: advice}} =
             PhoenixKitWarehouse.api_problems()

    assert is_binary(advice)
  end
end
