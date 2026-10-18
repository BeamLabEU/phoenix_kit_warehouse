defmodule PhoenixKitWarehouse.CreateAndPostTest do
  @moduledoc """
  `create_and_post/2` for goods issues, goods receipts and inventory
  documents: one transaction that creates the document and posts it, so a
  failure leaves no draft row and burns no document number.

  Stock has no FK to the catalogue, so lines use bare item UUIDs.
  """

  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsIssues
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.GoodsReceipts
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.StockLedger

  @location "00000000-0000-0000-0000-000000000001"

  defp item_uuid, do: Ecto.UUID.generate()

  defp seed!(item, qty, opts \\ []) do
    {:ok, _} =
      StockLedger.upsert_quantity(item, Decimal.new(to_string(qty)),
        location_uuid: Keyword.get(opts, :location, @location)
      )
  end

  defp qty(item), do: StockLedger.get_quantity(item, @location)

  defp issue_line(item, quantity), do: %{"item_uuid" => item, "issued_quantity" => quantity}
  defp receipt_line(item, quantity), do: %{"item_uuid" => item, "received_quantity" => quantity}
  defp count_line(item, quantity), do: %{"item_uuid" => item, "counted_quantity" => quantity}

  defp issue_attrs(lines, extra \\ %{}) do
    Map.merge(%{location_uuid: @location, lines: lines}, extra)
  end

  defp row_count(schema), do: Repo.aggregate(schema, :count)

  # `number` comes from a sequence, and sequences are not rolled back with
  # the transaction: the only way a failed create-and-post "burns no number"
  # is by failing before the INSERT that calls nextval.
  defp sequence_state(table) do
    %{rows: [[last, called?]]} =
      Repo.query!("SELECT last_value, is_called FROM phoenix_kit_warehouse_#{table}_number_seq")

    {last, called?}
  end

  describe "GoodsIssues.create_and_post/2" do
    test "creates and posts in one step: stock decremented, audit trail, reason and ref stored" do
      a = item_uuid()
      b = item_uuid()
      seed!(a, 10)
      seed!(b, 5)

      assert {:ok, %GoodsIssue{} = issue} =
               GoodsIssues.create_and_post(
                 issue_attrs([issue_line(a, "4"), issue_line(b, 5)], %{
                   reason: "sale",
                   external_ref: "SHOP-1001",
                   note: "web order"
                 }),
                 nil
               )

      assert issue.status == "posted"
      assert issue.reason == "sale"
      assert issue.external_ref == "SHOP-1001"
      assert issue.posted_at

      assert Decimal.equal?(qty(a), Decimal.new("6"))
      assert Decimal.equal?(qty(b), Decimal.new("0"))

      persisted = Repo.get!(GoodsIssue, issue.uuid)
      by_item = Map.new(persisted.lines, &{&1["item_uuid"], &1})
      assert Decimal.equal?(by_item[a]["previous_quantity"], Decimal.new("10"))
      assert Decimal.equal?(by_item[b]["previous_quantity"], Decimal.new("5"))
    end

    test "source_refs are stored with the document in the same transaction" do
      a = item_uuid()
      seed!(a, 3)
      ref = %{"type" => "internal_order", "uuid" => Ecto.UUID.generate()}

      assert {:ok, issue} =
               GoodsIssues.create_and_post(
                 issue_attrs([issue_line(a, 1)], %{source_refs: [ref]}),
                 nil
               )

      assert issue.source_refs == [ref]
      assert Repo.get!(GoodsIssue, issue.uuid).source_refs == [ref]
    end

    test "a posting refused for stock leaves no document behind" do
      a = item_uuid()
      seed!(a, 1)
      before = row_count(GoodsIssue)
      ref = %{"type" => "internal_order", "uuid" => Ecto.UUID.generate()}

      assert {:error, {:insufficient_stock, [_short]}} =
               GoodsIssues.create_and_post(
                 issue_attrs([issue_line(a, 5)], %{source_refs: [ref]}),
                 nil
               )

      assert row_count(GoodsIssue) == before
    end

    test "reason defaults to production" do
      a = item_uuid()
      seed!(a, 3)

      assert {:ok, issue} = GoodsIssues.create_and_post(issue_attrs([issue_line(a, 1)]), nil)
      assert issue.reason == "production"
    end

    test "string-keyed attrs and atom-keyed lines are accepted" do
      a = item_uuid()
      seed!(a, 3)

      attrs = %{
        "location_uuid" => @location,
        "reason" => "damage",
        "lines" => [%{item_uuid: a, issued_quantity: 2}]
      }

      assert {:ok, issue} = GoodsIssues.create_and_post(attrs, nil)
      assert issue.reason == "damage"
      assert Decimal.equal?(qty(a), Decimal.new("1"))
    end

    test "an unknown reason is a changeset error and nothing is written" do
      a = item_uuid()
      seed!(a, 3)
      before = row_count(GoodsIssue)

      assert {:error, %Ecto.Changeset{} = changeset} =
               GoodsIssues.create_and_post(
                 issue_attrs([issue_line(a, 1)], %{reason: "gift"}),
                 nil
               )

      assert %{reason: [_]} = errors_on(changeset)
      assert row_count(GoodsIssue) == before
      assert Decimal.equal?(qty(a), Decimal.new("3"))
    end

    test "reports EVERY short line, with requested and available, and writes nothing" do
      ok_item = item_uuid()
      short_a = item_uuid()
      short_b = item_uuid()
      no_row = item_uuid()
      seed!(ok_item, 10)
      seed!(short_a, 2)
      seed!(short_b, 1)

      before = row_count(GoodsIssue)
      seq_before = sequence_state("goods_issues")

      lines = [
        issue_line(short_a, "5"),
        issue_line(ok_item, "3"),
        issue_line(short_b, "1.5"),
        issue_line(no_row, "1")
      ]

      assert {:error, {:insufficient_stock, short}} =
               GoodsIssues.create_and_post(issue_attrs(lines), nil)

      assert Enum.map(short, & &1.item_uuid) == [short_a, short_b, no_row]

      [first, second, third] = short
      assert Decimal.equal?(first.requested, Decimal.new("5"))
      assert Decimal.equal?(first.available, Decimal.new("2"))
      assert Decimal.equal?(second.requested, Decimal.new("1.5"))
      assert Decimal.equal?(second.available, Decimal.new("1"))
      assert Decimal.equal?(third.requested, Decimal.new("1"))
      assert Decimal.equal?(third.available, Decimal.new("0"))

      # Nothing moved, no draft row, and no document number was consumed.
      assert Decimal.equal?(qty(ok_item), Decimal.new("10"))
      assert Decimal.equal?(qty(short_a), Decimal.new("2"))
      assert row_count(GoodsIssue) == before
      assert sequence_state("goods_issues") == seq_before
    end

    test "a failed create-and-post burns no document number" do
      a = item_uuid()
      seed!(a, 1)

      {:ok, first} = GoodsIssues.create_and_post(issue_attrs([issue_line(a, 1)]), nil)

      assert {:error, {:insufficient_stock, _}} =
               GoodsIssues.create_and_post(issue_attrs([issue_line(a, 1)]), nil)

      seed!(a, 1)
      {:ok, second} = GoodsIssues.create_and_post(issue_attrs([issue_line(a, 1)]), nil)

      assert second.number == first.number + 1
    end

    test "refuses duplicate item lines instead of dropping one" do
      a = item_uuid()
      b = item_uuid()
      seed!(a, 10)
      seed!(b, 10)
      before = row_count(GoodsIssue)

      lines = [issue_line(a, 1), issue_line(b, 1), issue_line(a, 2)]

      assert {:error, {:duplicate_lines, [^a]}} =
               GoodsIssues.create_and_post(issue_attrs(lines), nil)

      assert row_count(GoodsIssue) == before
      assert Decimal.equal?(qty(a), Decimal.new("10"))
      assert Decimal.equal?(qty(b), Decimal.new("10"))
    end

    test "refuses a negative quantity (it would otherwise ADD stock)" do
      a = item_uuid()
      seed!(a, 4)

      assert {:error, {:invalid_quantity, [^a]}} =
               GoodsIssues.create_and_post(issue_attrs([issue_line(a, "-3")]), nil)

      assert Decimal.equal?(qty(a), Decimal.new("4"))
    end

    test "refuses empty lines and lines without a valid item_uuid" do
      assert {:error, :no_lines} = GoodsIssues.create_and_post(issue_attrs([]), nil)

      assert {:error, :invalid_lines} =
               GoodsIssues.create_and_post(issue_attrs([%{"issued_quantity" => 1}]), nil)

      assert {:error, :invalid_lines} =
               GoodsIssues.create_and_post(issue_attrs([issue_line("not-a-uuid", 1)]), nil)
    end

    test "a posted document with the same external_ref answers :already_posted, once" do
      a = item_uuid()
      seed!(a, 10)
      attrs = issue_attrs([issue_line(a, 4)], %{external_ref: "EXT-7"})

      assert {:ok, first} = GoodsIssues.create_and_post(attrs, nil)
      before = row_count(GoodsIssue)

      assert {:ok, :already_posted, existing} = GoodsIssues.create_and_post(attrs, nil)
      assert existing.uuid == first.uuid
      assert existing.number == first.number

      assert row_count(GoodsIssue) == before
      assert Decimal.equal?(qty(a), Decimal.new("6"))
    end

    test "the retry is answered even when stock would no longer cover it" do
      a = item_uuid()
      seed!(a, 4)
      attrs = issue_attrs([issue_line(a, 4)], %{external_ref: "EXT-8"})

      assert {:ok, first} = GoodsIssues.create_and_post(attrs, nil)
      assert Decimal.equal?(qty(a), Decimal.new("0"))

      assert {:ok, :already_posted, existing} = GoodsIssues.create_and_post(attrs, nil)
      assert existing.uuid == first.uuid
    end

    test "external_ref is per document type, and a draft carrying it does not count" do
      a = item_uuid()
      seed!(a, 10)

      {:ok, _draft} =
        GoodsIssues.create_goods_issue(%{location_uuid: @location, external_ref: "EXT-9"})

      assert {:ok, %GoodsIssue{}} =
               GoodsIssues.create_and_post(
                 issue_attrs([issue_line(a, 1)], %{external_ref: "EXT-9"}),
                 nil
               )

      # Same ref on a receipt is a different document type: independent.
      assert {:ok, %GoodsReceipt{}} =
               GoodsReceipts.create_and_post(
                 issue_attrs([receipt_line(a, 1)], %{external_ref: "EXT-9"}),
                 nil
               )
    end

    test "two posted goods issues cannot share an external_ref even through the plain post path" do
      a = item_uuid()
      seed!(a, 10)

      {:ok, first} =
        GoodsIssues.create_goods_issue(%{
          location_uuid: @location,
          external_ref: "EXT-10",
          lines: [%{"item_uuid" => a, "issued_quantity" => Decimal.new("1")}]
        })

      {:ok, second} =
        GoodsIssues.create_goods_issue(%{
          location_uuid: @location,
          external_ref: "EXT-10",
          lines: [%{"item_uuid" => a, "issued_quantity" => Decimal.new("1")}]
        })

      assert {:ok, _} = GoodsIssues.post_goods_issue(first, nil)

      # The index turns the second post into an error, not an exception, and
      # the whole post (stock included) rolls back.
      assert {:error, %Ecto.Changeset{} = changeset} = GoodsIssues.post_goods_issue(second, nil)
      assert %{external_ref: [_]} = errors_on(changeset)
      assert Decimal.equal?(qty(a), Decimal.new("9"))
    end
  end

  describe "GoodsReceipts.create_and_post/2" do
    test "creates and posts: stock increased, previous quantity recorded" do
      a = item_uuid()
      b = item_uuid()
      seed!(a, 3)

      assert {:ok, %GoodsReceipt{} = receipt} =
               GoodsReceipts.create_and_post(
                 issue_attrs([receipt_line(a, "2"), receipt_line(b, 7)], %{
                   external_ref: "PO-55"
                 }),
                 nil
               )

      assert receipt.status == "posted"
      assert receipt.external_ref == "PO-55"
      assert Decimal.equal?(qty(a), Decimal.new("5"))
      assert Decimal.equal?(qty(b), Decimal.new("7"))

      by_item = Map.new(Repo.get!(GoodsReceipt, receipt.uuid).lines, &{&1["item_uuid"], &1})
      assert Decimal.equal?(by_item[a]["previous_quantity"], Decimal.new("3"))
      assert Decimal.equal?(by_item[b]["previous_quantity"], Decimal.new("0"))
    end

    test "source_refs are stored with the receipt in the same transaction" do
      a = item_uuid()
      ref = %{"type" => "supplier_order", "uuid" => Ecto.UUID.generate()}

      assert {:ok, receipt} =
               GoodsReceipts.create_and_post(
                 issue_attrs([receipt_line(a, 1)], %{source_refs: [ref]}),
                 nil
               )

      assert receipt.source_refs == [ref]
      assert Repo.get!(GoodsReceipt, receipt.uuid).source_refs == [ref]
    end

    test "refuses duplicate lines and negative quantities, leaving no draft and no number used" do
      a = item_uuid()
      b = item_uuid()
      before = row_count(GoodsReceipt)
      seq_before = sequence_state("goods_receipts")

      assert {:error, {:duplicate_lines, [^a]}} =
               GoodsReceipts.create_and_post(
                 issue_attrs([receipt_line(a, 1), receipt_line(a, 1)]),
                 nil
               )

      assert {:error, {:invalid_quantity, [^b]}} =
               GoodsReceipts.create_and_post(issue_attrs([receipt_line(b, "-1")]), nil)

      assert row_count(GoodsReceipt) == before
      assert sequence_state("goods_receipts") == seq_before
    end

    test "a posted receipt with the same external_ref answers :already_posted" do
      a = item_uuid()
      attrs = issue_attrs([receipt_line(a, 2)], %{external_ref: "PO-56"})

      assert {:ok, first} = GoodsReceipts.create_and_post(attrs, nil)
      assert {:ok, :already_posted, existing} = GoodsReceipts.create_and_post(attrs, nil)

      assert existing.uuid == first.uuid
      assert Decimal.equal?(qty(a), Decimal.new("2"))
    end
  end

  describe "Inventories.create_and_post/2" do
    test "creates and posts absolute counts, recording the exact prior quantity" do
      a = item_uuid()
      b = item_uuid()
      seed!(a, 9)

      assert {:ok, %InventoryDocument{} = doc} =
               Inventories.create_and_post(
                 issue_attrs([count_line(a, "4"), count_line(b, 6)], %{external_ref: "CNT-1"}),
                 nil
               )

      assert doc.status == "posted"
      assert doc.external_ref == "CNT-1"
      assert Decimal.equal?(qty(a), Decimal.new("4"))
      assert Decimal.equal?(qty(b), Decimal.new("6"))

      by_item = Map.new(Repo.get!(InventoryDocument, doc.uuid).lines, &{&1["item_uuid"], &1})
      assert Decimal.equal?(by_item[a]["previous_quantity"], Decimal.new("9"))
      assert Decimal.equal?(by_item[b]["previous_quantity"], Decimal.new("0"))
    end

    test "refuses duplicate lines instead of keeping the first" do
      a = item_uuid()
      before = row_count(InventoryDocument)
      seq_before = sequence_state("inventory_documents")

      assert {:error, {:duplicate_lines, [^a]}} =
               Inventories.create_and_post(
                 issue_attrs([count_line(a, 1), count_line(a, 2)]),
                 nil
               )

      assert row_count(InventoryDocument) == before
      assert sequence_state("inventory_documents") == seq_before
    end

    test "refuses a negative count" do
      a = item_uuid()

      assert {:error, {:invalid_quantity, [^a]}} =
               Inventories.create_and_post(issue_attrs([count_line(a, "-1")]), nil)
    end

    test "a posted inventory with the same external_ref answers :already_posted" do
      a = item_uuid()
      attrs = issue_attrs([count_line(a, 5)], %{external_ref: "CNT-2"})

      assert {:ok, first} = Inventories.create_and_post(attrs, nil)
      seed!(a, 99)

      assert {:ok, :already_posted, existing} = Inventories.create_and_post(attrs, nil)
      assert existing.uuid == first.uuid
      # The retry did not re-apply the count.
      assert Decimal.equal?(qty(a), Decimal.new("99"))
    end

    test "skip_unchanged: counts equal to the stock create no document and burn no number" do
      a = item_uuid()
      b = item_uuid()
      seed!(a, 9)
      seed!(b, 2)
      before = row_count(InventoryDocument)
      seq_before = sequence_state("inventory_documents")

      assert {:error, :unchanged} =
               Inventories.create_and_post(
                 issue_attrs([count_line(a, "9"), count_line(b, 2)], %{external_ref: "CNT-SAME"}),
                 nil,
                 skip_unchanged: true
               )

      assert row_count(InventoryDocument) == before
      assert sequence_state("inventory_documents") == seq_before
    end

    test "skip_unchanged: one changed line posts the document" do
      a = item_uuid()
      b = item_uuid()
      seed!(a, 9)
      seed!(b, 2)

      assert {:ok, %InventoryDocument{status: "posted"}} =
               Inventories.create_and_post(
                 issue_attrs([count_line(a, "9"), count_line(b, 3)]),
                 nil,
                 skip_unchanged: true
               )

      assert Decimal.equal?(qty(b), Decimal.new("3"))
    end

    test "skip_unchanged: another unit value on a valued document is a change" do
      a = item_uuid()
      line = %{"item_uuid" => a, "counted_quantity" => 2, "unit_value" => "3.50"}

      assert {:ok, _} =
               Inventories.create_and_post(issue_attrs([line], %{track_value: true}), nil)

      assert {:error, :unchanged} =
               Inventories.create_and_post(issue_attrs([line], %{track_value: true}), nil,
                 skip_unchanged: true
               )

      other = %{line | "unit_value" => "4.00"}

      assert {:ok, _} =
               Inventories.create_and_post(issue_attrs([other], %{track_value: true}), nil,
                 skip_unchanged: true
               )
    end

    test "without skip_unchanged an unchanged count still posts a document" do
      a = item_uuid()
      seed!(a, 9)

      assert {:ok, %InventoryDocument{status: "posted"}} =
               Inventories.create_and_post(issue_attrs([count_line(a, "9")]), nil)
    end

    test "track_value stores the line unit_value on the stock row" do
      a = item_uuid()

      line = %{"item_uuid" => a, "counted_quantity" => 2, "unit_value" => "3.50"}

      assert {:ok, _} =
               Inventories.create_and_post(issue_attrs([line], %{track_value: true}), nil)

      assert [%{unit_value: unit_value}] = StockLedger.stock_for_items([a])
      assert Decimal.equal?(unit_value, Decimal.new("3.50"))
    end
  end

  describe "location handling (all three create_and_post functions)" do
    @default "00000000-0000-4000-8000-00000000dead"

    # Runs `fun` with no default warehouse configured, restoring it afterwards.
    defp without_default_location(fun) do
      StockLedger.set_default_location_uuid(nil)
      fun.()
    after
      StockLedger.set_default_location_uuid(@default)
    end

    defp posters do
      [
        {GoodsIssues, GoodsIssue, &issue_line(&1, 1)},
        {GoodsReceipts, GoodsReceipt, &receipt_line(&1, 1)},
        {Inventories, InventoryDocument, &count_line(&1, 1)}
      ]
    end

    test "no location and no default warehouse is a changeset error, never a raise" do
      for {context, schema, line} <- posters(), location <- [:absent, nil, "", "  "] do
        a = item_uuid()
        seed!(a, 5, location: @default)
        before = row_count(schema)
        attrs = if location == :absent, do: %{}, else: %{location_uuid: location}

        assert {:error, %Ecto.Changeset{} = changeset} =
                 without_default_location(fn ->
                   context.create_and_post(Map.put(attrs, :lines, [line.(a)]), nil)
                 end)

        assert %{location_uuid: [_]} = errors_on(changeset)
        assert row_count(schema) == before
      end
    end

    test "a blank location falls back to the default warehouse" do
      for {context, _schema, line} <- posters(), location <- [nil, "", "  "] do
        a = item_uuid()
        seed!(a, 5, location: @default)

        assert {:ok, %{location_uuid: @default}} =
                 context.create_and_post(%{location_uuid: location, lines: [line.(a)]}, nil)
      end
    end
  end

  describe "quantity validation (all three create_and_post functions)" do
    test "a missing, nil, blank or unparseable quantity is refused, not read as zero" do
      for {context, schema, key} <- [
            {GoodsIssues, GoodsIssue, "issued_quantity"},
            {GoodsReceipts, GoodsReceipt, "received_quantity"},
            {Inventories, InventoryDocument, "counted_quantity"}
          ],
          bad <- [:missing, nil, "", "abc", %{}] do
        a = item_uuid()
        seed!(a, 5)
        before = row_count(schema)
        seq_before = sequence_state(sequence_table(schema))

        line = if bad == :missing, do: %{"item_uuid" => a}, else: %{"item_uuid" => a, key => bad}

        assert {:error, {:invalid_quantity, [^a]}} =
                 context.create_and_post(issue_attrs([line]), nil)

        assert row_count(schema) == before
        assert sequence_state(sequence_table(schema)) == seq_before
        assert Decimal.equal?(qty(a), Decimal.new("5"))
      end
    end

    test "an explicit zero is a valid quantity" do
      a = item_uuid()
      seed!(a, 5)
      assert {:ok, _} = Inventories.create_and_post(issue_attrs([count_line(a, 0)]), nil)
      assert Decimal.equal?(qty(a), Decimal.new("0"))
    end

    defp sequence_table(GoodsIssue), do: "goods_issues"
    defp sequence_table(GoodsReceipt), do: "goods_receipts"
    defp sequence_table(InventoryDocument), do: "inventory_documents"
  end

  describe "external_ref uniqueness (all three document types)" do
    test "the changeset path trims external_ref and counts its length in code points" do
      # One grapheme, 256 code points: Ecto's default grapheme count would let
      # it through and the varchar(255) column would raise.
      long = "e" <> String.duplicate("\u0301", 255)

      for {create, schema} <- [
            {&GoodsIssues.create_goods_issue/1, GoodsIssue},
            {&GoodsReceipts.create_goods_receipt/1, GoodsReceipt},
            {&Inventories.create_draft/1, InventoryDocument}
          ] do
        assert {:ok, trimmed} = create.(%{location_uuid: @location, external_ref: "  REF-1 "})
        assert trimmed.external_ref == "REF-1"
        assert Repo.get!(schema, trimmed.uuid).external_ref == "REF-1"

        assert {:error, %Ecto.Changeset{} = changeset} =
                 create.(%{location_uuid: @location, external_ref: long})

        assert %{external_ref: [_]} = errors_on(changeset)
      end
    end

    test "clearing an existing draft's external_ref through update_draft stores nil" do
      for {create, update, schema} <- [
            {&GoodsIssues.create_goods_issue/1, &GoodsIssues.update_draft/2, GoodsIssue},
            {&GoodsReceipts.create_goods_receipt/1, &GoodsReceipts.update_draft/2, GoodsReceipt},
            {&Inventories.create_draft/1, &Inventories.update_draft/2, InventoryDocument}
          ],
          cleared <- ["", nil, "   "] do
        {:ok, draft} = create.(%{location_uuid: @location, external_ref: "KEEP-1"})
        assert draft.external_ref == "KEEP-1"

        assert {:ok, updated} = update.(draft, %{external_ref: cleared})
        assert updated.external_ref == nil
        assert Repo.get!(schema, draft.uuid).external_ref == nil
      end
    end

    test "a soft-deleted posted document no longer answers :already_posted" do
      for {context, schema, line} <- [
            {GoodsIssues, GoodsIssue, &issue_line(&1, 1)},
            {GoodsReceipts, GoodsReceipt, &receipt_line(&1, 1)},
            {Inventories, InventoryDocument, &count_line(&1, 1)}
          ] do
        a = item_uuid()
        seed!(a, 5)
        attrs = issue_attrs([line.(a)], %{external_ref: "GONE-1"})

        assert {:ok, first} = context.create_and_post(attrs, nil)
        assert {:ok, :already_posted, _} = context.create_and_post(attrs, nil)

        Repo.update_all(from(d in schema, where: d.uuid == ^first.uuid),
          set: [deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

        assert {:ok, %{} = second} = context.create_and_post(attrs, nil)
        refute second.uuid == first.uuid
        assert second.external_ref == "GONE-1"
      end
    end

    test "two posted receipts cannot share an external_ref through the plain post path" do
      a = item_uuid()

      draft = fn ->
        {:ok, receipt} =
          GoodsReceipts.create_goods_receipt(%{
            location_uuid: @location,
            external_ref: "EXT-R",
            lines: [%{"item_uuid" => a, "received_quantity" => Decimal.new("1")}]
          })

        receipt
      end

      first = draft.()
      second = draft.()

      assert {:ok, _} = GoodsReceipts.post_goods_receipt(first, nil)

      assert {:error, %Ecto.Changeset{} = changeset} =
               GoodsReceipts.post_goods_receipt(second, nil)

      assert %{external_ref: [_]} = errors_on(changeset)
      assert Decimal.equal?(qty(a), Decimal.new("1"))
    end

    test "two posted inventory documents cannot share an external_ref through the plain post path" do
      a = item_uuid()

      draft = fn count ->
        {:ok, doc} =
          Inventories.create_draft(%{
            location_uuid: @location,
            external_ref: "EXT-I",
            lines: [%{"item_uuid" => a, "counted_quantity" => Decimal.new(count)}]
          })

        doc
      end

      first = draft.("3")
      second = draft.("8")

      assert {:ok, _} = Inventories.post_document(first, nil)
      assert {:error, %Ecto.Changeset{} = changeset} = Inventories.post_document(second, nil)
      assert %{external_ref: [_]} = errors_on(changeset)
      assert Decimal.equal?(qty(a), Decimal.new("3"))
    end
  end

  describe "Inventories.post_document/2 reads the prior quantity inside the transaction" do
    test "the stock read is a locking read issued after the transaction begins" do
      a = item_uuid()
      seed!(a, 9)

      {:ok, doc} =
        Inventories.create_draft(%{
          location_uuid: @location,
          lines: [%{"item_uuid" => a, "counted_quantity" => Decimal.new("4")}]
        })

      queries = capture_queries(fn -> Inventories.post_document(doc, nil) end)

      begin_at = Enum.find_index(queries, &(&1 =~ ~r/^(begin|savepoint)/i))

      read_at =
        Enum.find_index(queries, &(&1 =~ "phoenix_kit_warehouse_stock" and &1 =~ "SELECT"))

      write_at =
        Enum.find_index(
          queries,
          &(&1 =~ "INSERT INTO" and &1 =~ "phoenix_kit_warehouse_stock" and &1 =~ "DO UPDATE")
        )

      assert begin_at, "no transaction start seen in #{inspect(queries)}"
      assert read_at, "no stock read seen in #{inspect(queries)}"
      assert write_at, "no stock write seen in #{inspect(queries)}"

      assert begin_at < read_at,
             "the prior stock was read BEFORE the transaction began: #{inspect(queries)}"

      assert read_at < write_at
      assert Enum.at(queries, read_at) =~ "FOR UPDATE"
    end

    test "an item with no stock row yet gets its row claimed before the locking read" do
      present = item_uuid()
      absent = item_uuid()
      seed!(present, 9)

      {:ok, doc} =
        Inventories.create_draft(%{
          location_uuid: @location,
          lines: [
            %{"item_uuid" => present, "counted_quantity" => Decimal.new("4")},
            %{"item_uuid" => absent, "counted_quantity" => Decimal.new("2")}
          ]
        })

      queries = capture_queries(fn -> Inventories.post_document(doc, nil) end)

      claim_at =
        Enum.find_index(
          queries,
          &(&1 =~ "INSERT INTO" and &1 =~ "phoenix_kit_warehouse_stock" and
              &1 =~ "DO NOTHING")
        )

      read_at =
        Enum.find_index(queries, &(&1 =~ "phoenix_kit_warehouse_stock" and &1 =~ "FOR UPDATE"))

      assert claim_at, "no stock-row claim seen in #{inspect(queries)}"
      assert read_at, "no locking read seen in #{inspect(queries)}"

      assert claim_at < read_at,
             "a row inserted by a concurrent transaction could slip past the lock: #{inspect(queries)}"

      by_item = Map.new(Repo.get!(InventoryDocument, doc.uuid).lines, &{&1["item_uuid"], &1})
      assert Decimal.equal?(by_item[present]["previous_quantity"], Decimal.new("9"))
      assert Decimal.equal?(by_item[absent]["previous_quantity"], Decimal.new("0"))
      assert Decimal.equal?(qty(present), Decimal.new("4"))
      assert Decimal.equal?(qty(absent), Decimal.new("2"))
    end

    test "repost_document reads the prior quantity inside its transaction too" do
      a = item_uuid()
      seed!(a, 9)

      {:ok, doc} =
        Inventories.create_draft(%{
          location_uuid: @location,
          lines: [%{"item_uuid" => a, "counted_quantity" => Decimal.new("4")}]
        })

      {:ok, posted} = Inventories.post_document(doc, nil)
      seed!(a, 20)

      queries = capture_queries(fn -> Inventories.repost_document(posted, nil) end)

      begin_at = Enum.find_index(queries, &(&1 =~ ~r/^(begin|savepoint)/i))

      read_at =
        Enum.find_index(queries, &(&1 =~ "phoenix_kit_warehouse_stock" and &1 =~ "SELECT"))

      assert begin_at && read_at && begin_at < read_at
      assert Decimal.equal?(qty(a), Decimal.new("4"))

      by_item = Map.new(Repo.get!(InventoryDocument, posted.uuid).lines, &{&1["item_uuid"], &1})
      assert Decimal.equal?(by_item[a]["previous_quantity"], Decimal.new("20"))
    end
  end

  # Records the SQL text of every query the calling process issues while `fun`
  # runs. Ecto emits one telemetry event per query (and per transaction
  # start), in the process that ran it, so the order is the real order.
  defp capture_queries(fun) do
    ref = make_ref()
    me = self()
    handler = "capture-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:phoenix_kit_warehouse, :test, :repo, :query],
      fn _event, _measurements, %{query: query}, _config -> send(me, {ref, query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain(ref, [])
  end

  defp drain(ref, acc) do
    receive do
      {^ref, query} -> drain(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
