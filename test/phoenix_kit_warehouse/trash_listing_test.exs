defmodule PhoenixKitWarehouse.TrashListingTest do
  @moduledoc """
  What the trash views of the internal and supplier order lists read: the
  `trashed: true` option of the list functions (the default list is unchanged),
  the trash counters, `SupplierOrders.list_replaceable_drafts/1` and the
  `:one_draft_per_source` switch.
  """

  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.InternalOrder
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.SupplierOrder
  alias PhoenixKitWarehouse.SupplierOrders

  @location "00000000-0000-0000-0000-000000000001"

  defp uuid, do: Ecto.UUID.generate()

  defp io!(attrs \\ %{}) do
    {:ok, io} =
      InternalOrders.create_internal_order(Map.merge(%{location_uuid: @location}, attrs))

    io
  end

  defp so!(attrs \\ %{}) do
    {:ok, so} =
      SupplierOrders.create_supplier_order(Map.merge(%{location_uuid: @location}, attrs))

    so
  end

  defp numbers(orders), do: Enum.map(orders, & &1.number)

  describe "list_internal_orders/1" do
    test "the default list is the live orders, the trashed option lists the trashed ones" do
      live = io!()
      {:ok, trashed} = InternalOrders.soft_delete_internal_order(io!(), uuid())

      assert live.number in numbers(InternalOrders.list_internal_orders())
      refute trashed.number in numbers(InternalOrders.list_internal_orders())
      refute trashed.number in numbers(InternalOrders.list_internal_orders([]))

      assert trashed.number in numbers(InternalOrders.list_internal_orders(trashed: true))
      refute live.number in numbers(InternalOrders.list_internal_orders(trashed: true))
      refute trashed.number in numbers(InternalOrders.list_internal_orders(trashed: false))
    end

    test "a trashed posted order (legacy) is listed in the trash too" do
      posted = io!() |> post_io!()

      {1, _} =
        Repo.update_all(
          from(o in InternalOrder, where: o.uuid == ^posted.uuid),
          set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

      assert posted.number in numbers(InternalOrders.list_internal_orders(trashed: true))
      refute posted.number in numbers(InternalOrders.list_internal_orders())
    end

    test "count_trashed_internal_orders/0 counts the trashed ones, posted included" do
      before_count = InternalOrders.count_trashed_internal_orders()
      io!()
      {:ok, _} = InternalOrders.soft_delete_internal_order(io!(), uuid())
      posted = io!() |> post_io!()

      {1, _} =
        Repo.update_all(
          from(o in InternalOrder, where: o.uuid == ^posted.uuid),
          set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

      assert InternalOrders.count_trashed_internal_orders() == before_count + 2
    end
  end

  describe "list_supplier_orders/1" do
    test "the default list is the live orders, the trashed option lists the trashed ones" do
      live = so!()
      {:ok, trashed} = SupplierOrders.soft_delete_supplier_order(so!(), uuid())

      assert live.number in numbers(SupplierOrders.list_supplier_orders())
      refute trashed.number in numbers(SupplierOrders.list_supplier_orders())
      refute trashed.number in numbers(SupplierOrders.list_supplier_orders([]))

      assert trashed.number in numbers(SupplierOrders.list_supplier_orders(trashed: true))
      refute live.number in numbers(SupplierOrders.list_supplier_orders(trashed: true))
    end

    test "count_trashed_supplier_orders/0 counts the trashed ones, posted included" do
      before_count = SupplierOrders.count_trashed_supplier_orders()
      so!()
      {:ok, _} = SupplierOrders.soft_delete_supplier_order(so!(), uuid())
      posted = so!(%{supplier_uuid: uuid()}) |> post_so!()

      {1, _} =
        Repo.update_all(
          from(o in SupplierOrder, where: o.uuid == ^posted.uuid),
          set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

      assert SupplierOrders.count_trashed_supplier_orders() == before_count + 2
    end
  end

  describe "SupplierOrders.list_replaceable_drafts/1" do
    test "lists the live drafts of the internal order that a generation could replace" do
      io = io!() |> post_io!()
      supplier = uuid()
      other_io = io!() |> post_io!()

      mine = so!(%{internal_order_uuid: io.uuid, supplier_uuid: supplier})

      # posted, trashed, without a supplier, combined, and another order's: never listed
      posted =
        so!(%{internal_order_uuid: io.uuid, supplier_uuid: supplier}) |> post_so!()

      {:ok, _} =
        so!(%{internal_order_uuid: io.uuid, supplier_uuid: supplier})
        |> SupplierOrders.soft_delete_supplier_order(uuid())

      no_supplier = so!(%{internal_order_uuid: io.uuid})

      combined =
        so!(%{
          internal_order_uuid: io.uuid,
          supplier_uuid: supplier,
          source_refs: [
            %{"type" => "internal_order", "uuid" => io.uuid},
            %{"type" => "internal_order", "uuid" => other_io.uuid}
          ]
        })

      foreign = so!(%{internal_order_uuid: other_io.uuid, supplier_uuid: supplier})

      listed = Enum.map(SupplierOrders.list_replaceable_drafts(io.uuid), & &1.uuid)

      assert listed == [mine.uuid]
      refute posted.uuid in listed
      refute no_supplier.uuid in listed
      refute combined.uuid in listed
      refute foreign.uuid in listed
    end

    test "an own source ref does not make a draft combined" do
      io = io!() |> post_io!()

      draft =
        so!(%{
          internal_order_uuid: io.uuid,
          supplier_uuid: uuid(),
          source_refs: [%{"type" => "internal_order", "uuid" => io.uuid}]
        })

      assert [%{uuid: uuid}] = SupplierOrders.list_replaceable_drafts(io.uuid)
      assert uuid == draft.uuid
    end
  end

  describe "PhoenixKitWarehouse.one_draft_per_source?/0" do
    setup do
      previous = Application.fetch_env(:phoenix_kit_warehouse, :one_draft_per_source)

      on_exit(fn ->
        case previous do
          {:ok, value} ->
            Application.put_env(:phoenix_kit_warehouse, :one_draft_per_source, value)

          :error ->
            Application.delete_env(:phoenix_kit_warehouse, :one_draft_per_source)
        end
      end)

      :ok
    end

    test "is off by default and follows the config" do
      Application.delete_env(:phoenix_kit_warehouse, :one_draft_per_source)
      refute PhoenixKitWarehouse.one_draft_per_source?()

      Application.put_env(:phoenix_kit_warehouse, :one_draft_per_source, true)
      assert PhoenixKitWarehouse.one_draft_per_source?()

      Application.put_env(:phoenix_kit_warehouse, :one_draft_per_source, false)
      refute PhoenixKitWarehouse.one_draft_per_source?()
    end

    test "only the value true switches it on" do
      for value <- [nil, "true", 1, :yes] do
        Application.put_env(:phoenix_kit_warehouse, :one_draft_per_source, value)
        refute PhoenixKitWarehouse.one_draft_per_source?()
      end
    end
  end

  defp post_io!(io) do
    {:ok, posted} = InternalOrders.post_internal_order(io, nil)
    posted
  end

  defp post_so!(so) do
    {:ok, posted} = SupplierOrders.post_supplier_order(so, nil)
    posted
  end
end
