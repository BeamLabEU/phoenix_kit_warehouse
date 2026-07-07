defmodule PhoenixKitWarehouse.Test.Fixtures do
  @moduledoc """
  Standalone fixture helpers for the phoenix_kit_warehouse test suite.

  Provides the same interface as `Andi.Fixtures.insert_order!/0` without
  depending on the host application.  Uses `FakeOrderSources` (an in-memory
  Agent) to satisfy `SourceKinds.resolve/2` calls made by LiveViews during
  tests that exercise the source-picker and traceability-chain flows.
  """

  alias PhoenixKitWarehouse.Test.FakeOrderSources

  @doc """
  Creates a fake "customer order" record visible to the `SourceKinds`
  registry.

  Registers the `FakeOrderSources.order_kind()` source kind if it is not
  already present, puts the new fake order into the `FakeOrderSources`
  Agent, and returns a map shaped like `%{uuid: uuid, data: %{"order_number"
  => number_string}}` — enough for test assertions that check
  `customer_order.uuid` and `customer_order.data["order_number"]`.

  An `on_exit/1` callback is registered to clean up the `:source_kinds`
  application env after the calling test finishes.
  """
  def insert_order! do
    uuid = Ecto.UUID.generate()
    number = System.unique_integer([:positive])
    label = "##{number}"

    existing = Application.get_env(:phoenix_kit_warehouse, :source_kinds, [])

    unless Enum.any?(existing, &(&1[:kind] == "order")) do
      Application.put_env(
        :phoenix_kit_warehouse,
        :source_kinds,
        [FakeOrderSources.order_kind() | existing]
      )

      ExUnit.Callbacks.on_exit(fn ->
        Application.delete_env(:phoenix_kit_warehouse, :source_kinds)
      end)
    end

    FakeOrderSources.put_order(%{uuid: uuid, label: label, lines: []})

    %{uuid: uuid, data: %{"order_number" => to_string(number)}}
  end
end
