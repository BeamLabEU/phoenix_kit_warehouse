defmodule PhoenixKitWarehouse.Web.TrashActionsTest do
  @moduledoc """
  The shared "Move to trash" pieces without a database: why a document cannot
  go to the trash (`TrashActions.blocked_reason/1`), how the flash names it
  (`TrashMessages.tag/1`), the document kinds, and the markup of the menu item,
  the form button and the confirmation.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWarehouse.{
    GoodsIssue,
    GoodsReceipt,
    InternalOrder,
    InventoryDocument,
    SupplierOrder,
    Transfer
  }

  alias PhoenixKitWarehouse.Web.Components.TrashAction
  alias PhoenixKitWarehouse.Web.{TrashActions, TrashMessages}

  @posted_kinds [InternalOrder, SupplierOrder, GoodsReceipt, GoodsIssue, InventoryDocument]
  @trashed_at ~U[2026-10-21 10:00:00Z]

  describe "blocked_reason/1" do
    test "a live draft of every kind can go to the trash" do
      for schema <- @posted_kinds ++ [Transfer] do
        assert TrashActions.blocked_reason(struct(schema, status: "draft")) == nil
      end
    end

    test "a posted document of every kind that posts cannot" do
      for schema <- @posted_kinds do
        assert TrashActions.blocked_reason(struct(schema, status: "posted")) ==
                 "A posted document cannot be deleted"
      end
    end

    test "a transfer gets the reason of its status" do
      assert TrashActions.blocked_reason(%Transfer{status: "in_transit"}) ==
               "A transfer in transit cannot be deleted — cancel it first"

      assert TrashActions.blocked_reason(%Transfer{status: "done"}) ==
               "A completed transfer cannot be deleted"

      assert TrashActions.blocked_reason(%Transfer{status: "cancelled"}) ==
               "A cancelled transfer cannot be deleted"
    end

    test "a document already in the trash says so, draft or not" do
      for schema <- @posted_kinds ++ [Transfer], status <- ~w(draft posted) do
        assert TrashActions.blocked_reason(
                 struct(schema, status: status, deleted_at: @trashed_at)
               ) == "The document is already in the trash"
      end
    end

    test "an unknown status gets the general reason" do
      assert TrashActions.blocked_reason(%InternalOrder{status: "archived"}) ==
               "This document cannot be deleted"

      assert TrashActions.blocked_reason(%Transfer{status: "posted"}) ==
               "This document cannot be deleted"
    end
  end

  describe "TrashMessages.tag/1" do
    test "names every kind as the lists print it" do
      assert TrashMessages.tag(%InternalOrder{number: 1}) == "#IO-1"
      assert TrashMessages.tag(%SupplierOrder{number: 2}) == "#SO-2"
      assert TrashMessages.tag(%GoodsReceipt{number: 3}) == "#GR-3"
      assert TrashMessages.tag(%GoodsIssue{number: 4}) == "#GI-4"
      assert TrashMessages.tag(%Transfer{number: 5}) == "#TR-5"
      assert TrashMessages.tag(%InventoryDocument{number: 6}) == "Inventory #6"
    end

    test "the stocktake label is translated" do
      Gettext.with_locale(PhoenixKitWarehouse.Gettext, "ru", fn ->
        assert TrashMessages.tag(%InventoryDocument{number: 6}) == "Инвентаризация #6"
      end)
    end

    test "the flashes name the document without a gendered verb" do
      assert TrashMessages.moved(%InventoryDocument{number: 6}) ==
               "Moved to the trash: Inventory #6."

      assert TrashMessages.restored(%InternalOrder{number: 1}, []) ==
               "Restored from the trash: #IO-1."
    end

    test "the over-reserve warning names the internal orders, and is left out without them" do
      assert TrashMessages.append_overcommitted("Done.", []) == "Done."

      assert TrashMessages.append_overcommitted("Done.", [
               %InternalOrder{number: 3},
               %InternalOrder{number: 5}
             ]) ==
               "Done. Goods issues exceed the order for: #IO-3, #IO-5 — check the lines."
    end
  end

  describe "kind/1" do
    test "describes all six kinds" do
      for name <- ~w(internal_order supplier_order goods_receipt goods_issue inventory transfer)a do
        kind = TrashActions.kind(name)

        assert is_function(kind.get, 1)
        assert is_function(kind.soft_delete, 2)
      end
    end

    test "the kinds restored without a swap also restore" do
      for name <- ~w(goods_receipt goods_issue inventory transfer)a do
        assert is_function(TrashActions.kind(name).restore, 2)
      end

      for name <- ~w(internal_order supplier_order)a do
        refute Map.has_key?(TrashActions.kind(name), :restore)
      end
    end
  end

  describe "trash_menu_item/1" do
    test "a draft gets an active item that asks for the confirmation" do
      html = render_component(&TrashAction.trash_menu_item/1, id_prefix: "io", uuid: "u1")

      [item] =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("#io-trash-u1") |> Enum.to_list()

      assert LazyHTML.attribute(item, "phx-click") == ["request_trash"]
      assert LazyHTML.attribute(item, "phx-value-uuid") == ["u1"]
      assert LazyHTML.attribute(item, "disabled") == []
      assert LazyHTML.text(item) =~ "Move to trash"
      refute html =~ "io-trash-reason-u1"
    end

    test "a blocked document gets a disabled item with the reason in sight" do
      html =
        render_component(&TrashAction.trash_menu_item/1,
          id_prefix: "io-card",
          uuid: "u1",
          reason: "A posted document cannot be deleted"
        )

      doc = LazyHTML.from_fragment(html)
      [item] = doc |> LazyHTML.query("#io-card-trash-u1") |> Enum.to_list()

      assert LazyHTML.attribute(item, "disabled") == [""]
      assert LazyHTML.attribute(item, "aria-disabled") == ["true"]
      assert LazyHTML.attribute(item, "role") == ["menuitem"]
      assert LazyHTML.attribute(item, "title") == ["A posted document cannot be deleted"]
      assert LazyHTML.attribute(item, "phx-click") == []

      assert doc |> LazyHTML.query("#io-card-trash-reason-u1") |> LazyHTML.text() |> String.trim() ==
               "A posted document cannot be deleted"
    end
  end

  describe "restore_menu_item/1" do
    test "sends restore with the uuid under the given prefix" do
      html = render_component(&TrashAction.restore_menu_item/1, id_prefix: "io-card", uuid: "u1")

      [item] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#io-card-restore-u1")
        |> Enum.to_list()

      assert LazyHTML.attribute(item, "phx-click") == ["restore"]
      assert LazyHTML.attribute(item, "phx-value-uuid") == ["u1"]
    end
  end

  describe "trash_button/1" do
    test "a draft gets an active button" do
      html = render_component(&TrashAction.trash_button/1, id_prefix: "io")
      [button] = html |> LazyHTML.from_fragment() |> LazyHTML.query("#io-trash") |> Enum.to_list()

      assert LazyHTML.attribute(button, "phx-click") == ["request_trash"]
      assert LazyHTML.attribute(button, "disabled") == []
      refute html =~ "data-tip"
    end

    test "a blocked document gets a disabled button with the reason as a tooltip" do
      reason = "A posted document cannot be deleted"
      html = render_component(&TrashAction.trash_button/1, id_prefix: "io", reason: reason)
      doc = LazyHTML.from_fragment(html)
      [button] = doc |> LazyHTML.query("#io-trash") |> Enum.to_list()

      assert LazyHTML.attribute(button, "disabled") == [""]
      assert LazyHTML.attribute(button, "phx-click") == []
      assert LazyHTML.attribute(button, "aria-describedby") == ["io-trash-reason"]

      assert doc |> LazyHTML.query(".tooltip[data-tip]") |> LazyHTML.attribute("data-tip") == [
               reason
             ]

      assert doc |> LazyHTML.query("#io-trash-reason.sr-only") |> LazyHTML.text() |> String.trim() ==
               reason
    end
  end

  describe "trash_confirm/1" do
    test "is not rendered without a candidate" do
      html = render_component(&TrashAction.trash_confirm/1, id_prefix: "io", candidate: nil)
      refute html =~ "io-trash-confirm-doc"
    end

    test "names the document once and drops the default prompt" do
      html =
        render_component(&TrashAction.trash_confirm/1,
          id_prefix: "io",
          candidate: %InternalOrder{number: 7}
        )

      doc = LazyHTML.from_fragment(html)

      assert doc |> LazyHTML.query("#io-trash-confirm-doc") |> LazyHTML.text() =~ "#IO-7"
      assert html =~ "Move to the trash?"
      assert html =~ ~s(phx-click="confirm_trash")
      assert html =~ ~s(phx-click="cancel_trash")
      refute html =~ "Do you want to continue?"
      refute html =~ "Unsaved changes"
    end

    test "in a form it warns that unsaved changes are lost" do
      html =
        render_component(&TrashAction.trash_confirm/1,
          id_prefix: "io",
          candidate: %InternalOrder{number: 7},
          form: true
        )

      assert html =~ "Unsaved changes in the form will not be saved."
      refute html =~ "Do you want to continue?"
    end
  end
end
