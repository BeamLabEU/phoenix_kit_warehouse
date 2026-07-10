defmodule PhoenixKitWarehouse.GoodsIssuesTest do
  @moduledoc false
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.Test.Repo
  alias PhoenixKitWarehouse.StockLedger, as: Warehouse
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.InternalOrders
  alias PhoenixKitWarehouse.Stock
  alias PhoenixKitCatalogue.Catalogue

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  @default_location_uuid "00000000-0000-0000-0000-000000000001"

  defp user_uuid do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "gi-test-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "GI",
        "last_name" => "Test"
      })

    user.uuid
  end

  defp create_catalogue! do
    {:ok, cat} =
      Catalogue.create_catalogue(%{
        name: "Test Catalogue #{System.unique_integer([:positive])}",
        status: "active"
      })

    cat
  end

  defp create_item! do
    catalogue = create_catalogue!()

    {:ok, item} =
      Catalogue.create_item(%{
        name: "Item #{System.unique_integer([:positive])}",
        catalogue_uuid: catalogue.uuid,
        status: "active"
      })

    item
  end

  defp seed_stock!(item_uuid, qty) do
    {:ok, _stock} =
      Warehouse.upsert_quantity(item_uuid, Decimal.new(to_string(qty)),
        location_uuid: @default_location_uuid
      )
  end

  defp sample_gi_line(item_uuid, opts \\ []) do
    issued = Keyword.get(opts, :issued, "0")
    required = Keyword.get(opts, :required, issued)

    %{
      "item_uuid" => item_uuid,
      "name" => "Material #{System.unique_integer([:positive])}",
      "sku" => "MAT-#{System.unique_integer([:positive])}",
      "unit" => "piece",
      "catalogue_uuid" => Ecto.UUID.generate(),
      "required_quantity" => Decimal.new(required),
      "issued_quantity" => Decimal.new(issued)
    }
  end

  defp create_draft!(attrs \\ %{}) do
    base = %{location_uuid: @default_location_uuid}
    {:ok, issue} = GoodsIssues.create_goods_issue(Map.merge(base, attrs))
    issue
  end

  defp create_posted_internal_order!(actor_uuid, extra_attrs \\ %{}) do
    item = create_item!()

    attrs =
      Map.merge(
        %{
          location_uuid: @default_location_uuid,
          lines: [
            %{
              "item_uuid" => item.uuid,
              "name" => item.name,
              "sku" => item.sku || "",
              "unit" => "piece",
              "catalogue_uuid" => item.catalogue_uuid,
              "category_uuid" => nil,
              "required_quantity" => Decimal.new("10")
            }
          ],
          created_by_uuid: actor_uuid
        },
        extra_attrs
      )

    {:ok, order} = InternalOrders.create_internal_order(attrs)
    {:ok, posted} = InternalOrders.post_internal_order(order, actor_uuid)
    {posted, item}
  end

  # ---------------------------------------------------------------------------
  # Warehouse.issue_quantity/3 tests
  # ---------------------------------------------------------------------------

  describe "Warehouse.issue_quantity/3" do
    test "decrements stock when sufficient (10 on hand, issue 4 → 6)" do
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10")

      {:ok, new_qty} =
        Warehouse.issue_quantity(item_uuid, Decimal.new("4"),
          location_uuid: @default_location_uuid
        )

      assert Decimal.equal?(new_qty, Decimal.new("6"))
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid), Decimal.new("6"))
    end

    test "issuing more than on-hand → {:error, {:insufficient_stock, item_uuid}} and stock unchanged" do
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "5")

      result =
        Warehouse.issue_quantity(item_uuid, Decimal.new("10"),
          location_uuid: @default_location_uuid
        )

      assert {:error, {:insufficient_stock, ^item_uuid}} = result
      # Stock must be unchanged
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid), Decimal.new("5"))
    end

    test "issuing against missing stock row → {:error, {:insufficient_stock, item_uuid}} (not silent 0-write)" do
      item_uuid = Ecto.UUID.generate()
      # No stock row exists for this item

      result =
        Warehouse.issue_quantity(item_uuid, Decimal.new("1"),
          location_uuid: @default_location_uuid
        )

      assert {:error, {:insufficient_stock, ^item_uuid}} = result
      # Confirm no row was created
      assert Repo.get_by(Stock, item_uuid: item_uuid) == nil
    end

    test "issuing exactly on-hand → success and stock becomes 0" do
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "7")

      {:ok, new_qty} =
        Warehouse.issue_quantity(item_uuid, Decimal.new("7"),
          location_uuid: @default_location_uuid
        )

      assert Decimal.equal?(new_qty, Decimal.new("0"))
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid), Decimal.new("0"))
    end

    test "uses default location when no location_uuid given" do
      item_uuid = Ecto.UUID.generate()

      # Seed at default location (which may be nil-mapped in test)
      {:ok, _} = Warehouse.upsert_quantity(item_uuid, Decimal.new("5"))

      result = Warehouse.issue_quantity(item_uuid, Decimal.new("3"))

      assert {:ok, new_qty} = result
      assert Decimal.equal?(new_qty, Decimal.new("2"))
    end

    test "is usable inside an Ecto.Multi" do
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "20")

      multi =
        Ecto.Multi.run(Ecto.Multi.new(), :issue, fn repo, _changes ->
          Warehouse.issue_quantity(item_uuid, Decimal.new("5"),
            location_uuid: @default_location_uuid,
            repo: repo
          )
        end)

      assert {:ok, %{issue: new_qty}} = Repo.transaction(multi)
      assert Decimal.equal?(new_qty, Decimal.new("15"))
    end
  end

  # ---------------------------------------------------------------------------
  # create_goods_issue/1
  # ---------------------------------------------------------------------------

  describe "create_goods_issue/1" do
    test "creates a draft with location_uuid" do
      issue = create_draft!()

      assert issue.status == "draft"
      assert issue.location_uuid == @default_location_uuid
      assert issue.uuid != nil
      assert issue.number != nil
    end

    test "assigns a unique number from the sequence" do
      i1 = create_draft!()
      i2 = create_draft!()

      assert i1.number != i2.number
    end

    test "falls back to the configured default location when location_uuid is missing" do
      assert {:ok, issue} = GoodsIssues.create_goods_issue(%{})
      assert issue.location_uuid == Warehouse.default_location_uuid()
    end

    test "stores lines" do
      item_uuid = Ecto.UUID.generate()
      lines = [sample_gi_line(item_uuid, issued: "5")]

      issue = create_draft!(%{lines: lines})

      assert length(issue.lines) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # create_from_internal_order/2
  # ---------------------------------------------------------------------------

  describe "create_from_internal_order/2" do
    test "issued_quantity defaults to required_quantity from the internal order" do
      actor = user_uuid()
      {order, item} = create_posted_internal_order!(actor)

      {:ok, issue} = GoodsIssues.create_from_internal_order(order, actor)

      assert issue.status == "draft"
      [line] = issue.lines
      assert line["item_uuid"] == item.uuid
      assert Decimal.equal?(Warehouse.to_decimal(line["issued_quantity"]), Decimal.new("10"))
    end

    test "sets internal_order_uuid and location_uuid from the internal order" do
      actor = user_uuid()
      {order, _item} = create_posted_internal_order!(actor)

      {:ok, issue} = GoodsIssues.create_from_internal_order(order, actor)

      assert issue.internal_order_uuid == order.uuid
      assert issue.location_uuid == order.location_uuid
    end

    test "sets created_by_uuid" do
      actor = user_uuid()
      {order, _item} = create_posted_internal_order!(actor)

      {:ok, issue} = GoodsIssues.create_from_internal_order(order, actor)

      assert issue.created_by_uuid == actor
    end

    test "carries name, sku, unit, catalogue_uuid from internal order lines" do
      actor = user_uuid()
      {order, item} = create_posted_internal_order!(actor)

      {:ok, issue} = GoodsIssues.create_from_internal_order(order, actor)

      [line] = issue.lines
      assert line["name"] == item.name
      assert line["catalogue_uuid"] == item.catalogue_uuid
    end

    test "deduplicates lines by item_uuid" do
      actor = user_uuid()
      item = create_item!()

      dup_line = %{
        "item_uuid" => item.uuid,
        "name" => item.name,
        "sku" => "",
        "unit" => "piece",
        "catalogue_uuid" => item.catalogue_uuid,
        "category_uuid" => nil,
        "required_quantity" => Decimal.new("5")
      }

      {:ok, order} =
        InternalOrders.create_internal_order(%{
          location_uuid: @default_location_uuid,
          lines: [dup_line, dup_line],
          created_by_uuid: actor
        })

      {:ok, posted} = InternalOrders.post_internal_order(order, actor)
      {:ok, issue} = GoodsIssues.create_from_internal_order(posted, actor)

      assert length(issue.lines) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # update_draft/2
  # ---------------------------------------------------------------------------

  describe "update_draft/2" do
    test "updates lines and note on a draft" do
      issue = create_draft!()
      item_uuid = Ecto.UUID.generate()
      lines = [sample_gi_line(item_uuid, issued: "5")]

      {:ok, updated} = GoodsIssues.update_draft(issue, %{lines: lines, note: "updated"})

      assert length(updated.lines) == 1
      assert updated.note == "updated"
    end

    test "returns {:error, :not_draft} for a posted issue" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10")
      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "5")]})
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)

      assert {:error, :not_draft} = GoodsIssues.update_draft(posted, %{note: "nope"})
    end
  end

  # ---------------------------------------------------------------------------
  # import_from_internal_orders/3 — chain derivation
  # ---------------------------------------------------------------------------

  describe "import_from_internal_orders/3 — chain derivation" do
    test "derives customer-order/sub-order refs transitively from the internal order(s)" do
      actor = user_uuid()
      order_ref = %{"type" => "order", "uuid" => Ecto.UUID.generate()}
      sub_order_ref = %{"type" => "sub_order", "uuid" => Ecto.UUID.generate()}

      {io, _item} =
        create_posted_internal_order!(actor, %{source_refs: [order_ref, sub_order_ref]})

      issue = create_draft!()

      assert {:ok, updated} =
               GoodsIssues.import_from_internal_orders(issue, [io.uuid], actor)

      refs = updated.source_refs

      assert Enum.any?(refs, &(&1["type"] == "internal_order" and &1["uuid"] == io.uuid))
      assert order_ref in refs
      assert sub_order_ref in refs
      assert length(refs) == 3
    end

    test "deduplicates the chain across multiple internal orders sharing a customer order" do
      actor = user_uuid()
      shared_ref = %{"type" => "order", "uuid" => Ecto.UUID.generate()}
      distinct_ref = %{"type" => "order", "uuid" => Ecto.UUID.generate()}

      {io1, _} = create_posted_internal_order!(actor, %{source_refs: [shared_ref]})
      {io2, _} = create_posted_internal_order!(actor, %{source_refs: [shared_ref, distinct_ref]})

      issue = create_draft!()

      assert {:ok, updated} =
               GoodsIssues.import_from_internal_orders(issue, [io1.uuid, io2.uuid], actor)

      refs = updated.source_refs

      assert Enum.any?(refs, &(&1["type"] == "internal_order" and &1["uuid"] == io1.uuid))
      assert Enum.any?(refs, &(&1["type"] == "internal_order" and &1["uuid"] == io2.uuid))
      assert shared_ref in refs
      assert distinct_ref in refs
      assert length(refs) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # add_source_ref/3 and remove_source_ref/3 — manual linking
  # ---------------------------------------------------------------------------

  describe "add_source_ref/3 and remove_source_ref/3" do
    test "attaches a reference without touching lines" do
      item_uuid = Ecto.UUID.generate()
      issue = create_draft!(%{lines: [sample_gi_line(item_uuid)]})
      uuid = Ecto.UUID.generate()

      assert {:ok, updated} = GoodsIssues.add_source_ref(issue, "order", uuid)

      assert %{"type" => "order", "uuid" => uuid} in updated.source_refs
      assert length(updated.lines) == 1
    end

    test "adding the same {type, uuid} twice is a no-op" do
      issue = create_draft!()
      uuid = Ecto.UUID.generate()

      {:ok, once} = GoodsIssues.add_source_ref(issue, "internal_order", uuid)
      {:ok, twice} = GoodsIssues.add_source_ref(once, "internal_order", uuid)

      assert length(twice.source_refs) == 1
    end

    test "removes an attached reference" do
      issue = create_draft!()
      uuid = Ecto.UUID.generate()

      {:ok, attached} = GoodsIssues.add_source_ref(issue, "internal_order", uuid)
      assert {:ok, removed} = GoodsIssues.remove_source_ref(attached, "internal_order", uuid)

      assert removed.source_refs == []
    end

    test "removing a reference that isn't present is a no-op" do
      issue = create_draft!()

      assert {:ok, updated} =
               GoodsIssues.remove_source_ref(issue, "order", Ecto.UUID.generate())

      assert updated.source_refs == []
    end

    test "works on a posted issue (metadata-only, not draft-gated)" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10")
      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "5")]})
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)
      uuid = Ecto.UUID.generate()

      assert {:ok, updated} = GoodsIssues.add_source_ref(posted, "order", uuid)
      assert %{"type" => "order", "uuid" => uuid} in updated.source_refs
      assert updated.status == "posted"
    end
  end

  # ---------------------------------------------------------------------------
  # post_goods_issue/2 — stock DECREASES
  # ---------------------------------------------------------------------------

  describe "post_goods_issue/2" do
    test "flips status to posted and sets posted_at and performed_by_uuid" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10")
      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "5")]})

      {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)

      assert posted.status == "posted"
      assert posted.posted_at != nil
      assert posted.performed_by_uuid == actor
    end

    test "DECREASES warehouse stock by issued_quantity" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10")

      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "4")]})

      {:ok, _posted} = GoodsIssues.post_goods_issue(issue, actor)

      qty = Warehouse.get_quantity(item_uuid)
      assert Decimal.equal?(qty, Decimal.new("6"))
    end

    test "insufficient stock on ANY line rolls back the WHOLE issue (no partial stock change)" do
      actor = user_uuid()
      item1_uuid = Ecto.UUID.generate()
      item2_uuid = Ecto.UUID.generate()

      # item1 has stock, item2 does NOT
      seed_stock!(item1_uuid, "10")

      lines = [
        sample_gi_line(item1_uuid, issued: "5"),
        sample_gi_line(item2_uuid, issued: "3")
      ]

      issue = create_draft!(%{lines: lines})

      result = GoodsIssues.post_goods_issue(issue, actor)

      assert {:error, {:insufficient_stock, ^item2_uuid}} = result

      # item1 stock must be UNCHANGED — whole transaction rolled back
      assert Decimal.equal?(Warehouse.get_quantity(item1_uuid), Decimal.new("10"))

      # Document must still be draft
      reloaded = GoodsIssues.get_goods_issue!(issue.uuid)
      assert reloaded.status == "draft"
    end

    test "issued_quantity 0 line is a no-op (no stock change)" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      # No stock at all — but issued=0 so it's a skip

      stock_before = Repo.all(Stock)
      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "0")]})
      {:ok, _posted} = GoodsIssues.post_goods_issue(issue, actor)
      stock_after = Repo.all(Stock)

      new_rows =
        Enum.reject(stock_after, fn s ->
          Enum.any?(stock_before, &(&1.uuid == s.uuid))
        end)

      assert new_rows == []
    end

    test "previous_quantity audit is captured in persisted lines" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "15")

      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "5")]})
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)

      [line] = posted.lines
      prev_qty = Warehouse.to_decimal(line["previous_quantity"])
      assert Decimal.equal?(prev_qty, Decimal.new("15"))
    end

    test "previous_quantity is 0 when item had no prior stock and issued=0 (no-op line)" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      # No stock — issued 0 so no error

      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "0")]})
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)

      [line] = posted.lines
      prev_qty = Warehouse.to_decimal(line["previous_quantity"])
      assert Decimal.equal?(prev_qty, Decimal.new("0"))
    end

    test "deduplicates lines by item_uuid on posting" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "20")

      dup_lines = [
        sample_gi_line(item_uuid, issued: "5"),
        sample_gi_line(item_uuid, issued: "3")
      ]

      issue = create_draft!(%{lines: dup_lines})
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)

      assert length(posted.lines) == 1
    end

    test "double-post guard: returns {:error, :not_draft}" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10")

      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "2")]})

      {:ok, _posted} = GoodsIssues.post_goods_issue(issue, actor)
      assert {:error, :not_draft} = GoodsIssues.post_goods_issue(issue, actor)
    end

    test "in-memory guard: post on a struct with status != draft returns {:error, :not_draft}" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10")

      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "2")]})
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)

      assert {:error, :not_draft} = GoodsIssues.post_goods_issue(posted, actor)
    end

    test "multiple items all decrease stock" do
      actor = user_uuid()
      item1 = Ecto.UUID.generate()
      item2 = Ecto.UUID.generate()
      seed_stock!(item1, "10")
      seed_stock!(item2, "8")

      lines = [
        sample_gi_line(item1, issued: "3"),
        sample_gi_line(item2, issued: "5")
      ]

      issue = create_draft!(%{lines: lines})
      {:ok, _posted} = GoodsIssues.post_goods_issue(issue, actor)

      assert Decimal.equal?(Warehouse.get_quantity(item1), Decimal.new("7"))
      assert Decimal.equal?(Warehouse.get_quantity(item2), Decimal.new("3"))
    end

    test "exact stock depletion (issue exactly on-hand) succeeds" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "5")

      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "5")]})
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)

      assert posted.status == "posted"
      assert Decimal.equal?(Warehouse.get_quantity(item_uuid), Decimal.new("0"))
    end

    test "Decimal math is preserved (no float rounding)" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10")

      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "3.5")]})
      {:ok, _posted} = GoodsIssues.post_goods_issue(issue, actor)

      qty = Warehouse.get_quantity(item_uuid)
      assert Decimal.equal?(qty, Decimal.new("6.5"))
    end
  end

  # ---------------------------------------------------------------------------
  # soft_delete/2
  # ---------------------------------------------------------------------------

  describe "soft_delete/2" do
    test "soft-deletes a draft issue" do
      actor = user_uuid()
      issue = create_draft!()

      {:ok, deleted} = GoodsIssues.soft_delete(issue, actor)

      assert deleted.deleted_at != nil
      assert deleted.deleted_by_uuid == actor
    end

    test "excludes soft-deleted issues from list" do
      actor = user_uuid()
      issue = create_draft!()
      {:ok, _} = GoodsIssues.soft_delete(issue, actor)

      all = GoodsIssues.list_goods_issues()
      refute Enum.any?(all, &(&1.uuid == issue.uuid))
    end

    test "returns {:error, :not_draft} for a posted issue" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10")
      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "2")]})
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)

      assert {:error, :not_draft} = GoodsIssues.soft_delete(posted, actor)
    end
  end

  # ---------------------------------------------------------------------------
  # correct_goods_issue/2
  # ---------------------------------------------------------------------------

  describe "correct_goods_issue/2" do
    test "updates note on a posted issue without changing status or lines" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10")
      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "2")]})
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)

      {:ok, corrected} = GoodsIssues.correct_goods_issue(posted, %{note: "corrected note"})

      assert corrected.note == "corrected note"
      assert corrected.status == "posted"
    end

    test "lines are immutable after posting (correction_changeset ignores lines)" do
      actor = user_uuid()
      item_uuid = Ecto.UUID.generate()
      seed_stock!(item_uuid, "10")
      issue = create_draft!(%{lines: [sample_gi_line(item_uuid, issued: "2")]})
      {:ok, posted} = GoodsIssues.post_goods_issue(issue, actor)

      {:ok, corrected} =
        GoodsIssues.correct_goods_issue(posted, %{
          note: "corrected",
          lines: []
        })

      assert length(corrected.lines) == length(posted.lines)
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  describe "list_goods_issues/0" do
    test "includes non-deleted issues" do
      issue = create_draft!()
      all = GoodsIssues.list_goods_issues()
      assert Enum.any?(all, &(&1.uuid == issue.uuid))
    end

    test "excludes soft-deleted issues" do
      actor = user_uuid()
      issue = create_draft!()
      {:ok, _} = GoodsIssues.soft_delete(issue, actor)

      all = GoodsIssues.list_goods_issues()
      refute Enum.any?(all, &(&1.uuid == issue.uuid))
    end
  end

  describe "get_goods_issue!/1 and get_goods_issue/1" do
    test "get_goods_issue!/1 raises on missing" do
      assert_raise Ecto.NoResultsError, fn ->
        GoodsIssues.get_goods_issue!(Ecto.UUID.generate())
      end
    end

    test "get_goods_issue/1 returns {:error, :not_found} on missing" do
      assert {:error, :not_found} = GoodsIssues.get_goods_issue(Ecto.UUID.generate())
    end

    test "get_goods_issue/1 returns {:ok, issue}" do
      issue = create_draft!()
      assert {:ok, found} = GoodsIssues.get_goods_issue(issue.uuid)
      assert found.uuid == issue.uuid
    end
  end

  # ---------------------------------------------------------------------------
  # import_from_internal_orders/3 — outstanding quantity (duplicate-issue prevention)
  # ---------------------------------------------------------------------------

  describe "import_from_internal_orders/3 — outstanding quantity (duplicate-issue prevention)" do
    test "a second goods issue for the same internal order only issues what's not already issued" do
      actor = user_uuid()
      {io, _item} = create_posted_internal_order!(actor)

      issue1 = create_draft!()
      {:ok, issue1} = GoodsIssues.import_from_internal_orders(issue1, [io.uuid], actor)
      assert [%{"issued_quantity" => q1}] = issue1.lines
      assert Decimal.equal?(Warehouse.to_decimal(q1), Decimal.new("10"))

      issue2 = create_draft!()
      {:ok, issue2} = GoodsIssues.import_from_internal_orders(issue2, [io.uuid], actor)

      assert issue2.lines == []
    end

    test "re-importing the same internal order into the same issue updates the ref's lines in place" do
      actor = user_uuid()
      {io, _item} = create_posted_internal_order!(actor)

      issue = create_draft!()
      {:ok, issue} = GoodsIssues.import_from_internal_orders(issue, [io.uuid], actor)
      {:ok, issue} = GoodsIssues.import_from_internal_orders(issue, [io.uuid], actor)

      refs_for_io = Enum.filter(issue.source_refs, &(&1["uuid"] == io.uuid))
      assert length(refs_for_io) == 1
    end
  end
end
