defmodule PhoenixKitWarehouse.InventoryAI.Apply do
  @moduledoc """
  Applies the ticked rows of a proposed run to a draft's lines (spec §11.1,
  §11.2, §11.6) - one transaction:

    1. the document row `FOR UPDATE`, a live draft (`:not_draft`, `:deleted`);
    2. the fingerprint of its lines in the database equal to the tab's base
       (`:stale` - another tab saved meanwhile); the document still on the
       warehouse the run was read for (`:location_changed`);
    3. the run moved `proposed -> applied` by a compare-and-set
       (`:not_proposed` - applied or discarded already, in this tab or
       another);
    4. every row checked (`{:invalid_rows, errors}`, nothing written): a row
       of the run's own proposal, an item that exists and is active, a
       quantity that is a finite number, not negative and below 10^12
       (`PhoenixKit.Utils.Number.parse_decimal/2` - a blank or unreadable
       quantity is an error, never 0), one row per item, an action the
       line allows;
    5. the rules of `PhoenixKitWarehouse.InventoryAI.Lines` applied to the
       tab's lines (the database's lines plus the tab's unsaved edits, the
       way "Save draft" writes them), the stock read in this transaction;
    6. the lines written, what was applied kept in the run's `decisions`,
       and the document read back with its new fingerprint - the tab's new
       buffer and base, together.

  The journal entry (`warehouse.inventory.ai_applied`) follows the commit.
  """

  use Gettext, backend: PhoenixKitWarehouse.Gettext

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Utils.Number
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.ActivityLog
  alias PhoenixKitWarehouse.DraftTrash
  alias PhoenixKitWarehouse.Inventories
  alias PhoenixKitWarehouse.InventoryAI
  alias PhoenixKitWarehouse.InventoryAI.Lines
  alias PhoenixKitWarehouse.InventoryAI.Proposal
  alias PhoenixKitWarehouse.InventoryAIRun
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.StockLedger
  alias PhoenixKitWarehouse.Web.Components.WarehouseBrowser

  @replacing ~w(replace replace_part replace_all)
  @adding ~w(add add_part)

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Applies `rows` of `run` to `socket_lines`, the lines of the tab whose base
  fingerprint is `base_fingerprint`; `actor` is who pressed Apply.

  A row: `%{"row" => n, "item_uuid" => uuid, "quantity" => qty}`, with
  `"action"` (the line's default when absent, see `Lines.choices/3`),
  `"package_size"` (the units per package a person typed) and
  `"merged_rows"` (the other rows of the proposal the table merged into
  this one: their objects count together, and none of them may be applied
  again) optional.

  `{:ok, %{document: doc, run: run, summary: summary}}` - `doc` read back,
  with `doc.lines` and `doc.fingerprint` the tab's new buffer and base.

  The lines are written into the run's own document. A fingerprint does not
  name a document - two drafts seeded from the same stock have the same
  lines - so the caller must pass the document its tab holds as
  `inventory_uuid:`; a run of another document, or a call without it, is
  refused (`:wrong_document`) before anything is locked.

  Options: `:inventory_uuid` (required); `:locale` - the language of the
  name of a new line, as "Add item" takes it (by default the language the
  run was started in).
  """
  @spec apply_run(InventoryAIRun.t(), String.t() | nil, [map()], [map()], term(), keyword()) ::
          {:ok, %{document: InventoryDocument.t(), run: InventoryAIRun.t(), summary: map()}}
          | {:error, term()}
  def apply_run(%InventoryAIRun{} = run, base_fingerprint, socket_lines, rows, actor, opts) do
    case Keyword.fetch(opts, :inventory_uuid) do
      {:ok, uuid} when uuid == run.inventory_uuid ->
        apply_to_document(run, base_fingerprint, socket_lines, rows, actor, locale(run, opts))

      _ ->
        {:error, :wrong_document}
    end
  end

  defp locale(run, opts) do
    Keyword.get(opts, :locale) || (run.result || %{})["locale"] ||
      Gettext.get_locale(PhoenixKitWarehouse.Gettext)
  end

  defp apply_to_document(run, base_fingerprint, socket_lines, rows, actor, locale) do
    actor_uuid = InventoryAI.actor_uuid(actor)

    InventoryDocument
    |> DraftTrash.lock_status_step(run.inventory_uuid, "draft", :not_draft)
    |> Ecto.Multi.run(:fingerprint, fn repo, %{lock_status: doc} ->
      if is_binary(base_fingerprint) and
           Inventories.fingerprint(doc.uuid, repo) == base_fingerprint,
         do: {:ok, base_fingerprint},
         else: {:error, :stale}
    end)
    |> Ecto.Multi.run(:location, fn _repo, %{lock_status: doc} ->
      if doc.location_uuid == run.location_uuid,
        do: {:ok, doc.location_uuid},
        else: {:error, :location_changed}
    end)
    |> Ecto.Multi.run(:claim, fn repo, _ -> claim(repo, run, actor_uuid) end)
    |> Ecto.Multi.run(:plan, fn repo, %{lock_status: doc, claim: claimed} ->
      plan(repo, claimed, doc, socket_lines, rows, locale)
    end)
    |> Ecto.Multi.update(:written, fn %{lock_status: doc, plan: plan} ->
      Ecto.Changeset.change(doc, lines: plan.lines)
    end)
    |> Ecto.Multi.run(:decisions, fn repo, %{claim: claimed, plan: plan} ->
      {1, [run]} =
        from(r in InventoryAIRun, where: r.uuid == ^claimed.uuid, select: r)
        |> repo.update_all(set: [decisions: plan.decisions, updated_at: InventoryAI.now()])

      {:ok, run}
    end)
    |> Ecto.Multi.run(:document, fn _repo, %{lock_status: doc} ->
      Inventories.get_document_with_fingerprint(doc.uuid)
    end)
    |> repo().transaction()
    |> case do
      {:ok, %{document: doc, decisions: run, plan: plan}} ->
        ActivityLog.log_inventory_ai_applied(doc, Map.put(plan.summary, :run_uuid, run.uuid),
          actor_uuid: actor_uuid,
          mode: "manual"
        )

        InventoryAI.broadcast(run)
        {:ok, %{document: doc, run: run, summary: plan.summary}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp claim(repo, run, actor_uuid) do
    now = InventoryAI.now()

    from(r in InventoryAIRun,
      where:
        r.uuid == ^run.uuid and r.inventory_uuid == ^run.inventory_uuid and r.status == "proposed",
      select: r
    )
    |> repo.update_all(
      set: [status: "applied", applied_by_uuid: actor_uuid, applied_at: now, updated_at: now]
    )
    |> case do
      {1, [claimed]} -> {:ok, claimed}
      {0, _} -> {:error, :not_proposed}
    end
  end

  # --- the plan: rows checked, lines computed -----------------------------------------

  defp plan(repo, run, doc, socket_lines, rows, locale) do
    proposal = Map.new((run.result || %{})["rows"] || [], &{&1["row"], &1})

    with :ok <- check_lines(socket_lines),
         {:ok, rows} <- check_rows(rows, proposal),
         {:ok, items} <- check_items(rows),
         stock = stock(repo, Map.keys(items), doc.location_uuid),
         {:ok, lines, applied} <- apply_rows(rows, items, stock, socket_lines, run, locale) do
      {:ok, %{lines: lines, decisions: decisions(applied), summary: summary(applied)}}
    end
  end

  defp check_lines(lines) when is_list(lines) do
    if Enum.all?(lines, &is_map/1), do: :ok, else: {:error, :invalid_lines}
  end

  defp check_lines(_lines), do: {:error, :invalid_lines}

  defp check_rows([], _proposal), do: {:error, :nothing_to_apply}

  defp check_rows(rows, proposal) when is_list(rows) do
    checked = Enum.map(rows, &check_row(&1, proposal))

    errors =
      Enum.flat_map(checked, fn
        {:error, errors} -> errors
        {:ok, _row} -> []
      end)

    rows = for {:ok, row} <- checked, do: row

    errors =
      errors ++ repeated_numbers(rows) ++ repeated(rows, :item_uuid, "item_uuid")

    if errors == [], do: {:ok, rows}, else: {:error, {:invalid_rows, errors}}
  end

  defp check_rows(_rows, _proposal), do: {:error, :nothing_to_apply}

  defp check_row(row, proposal) when is_map(row) do
    number = whole(row["row"])
    proposed = number && proposal[number]
    merged = merged_rows(row["merged_rows"], number, proposal)
    quantity = quantity(row["quantity"])
    package_size = package_size(row["package_size"])

    errors =
      []
      |> add_error(is_nil(proposed), number, "row", :unknown)
      |> add_error(merged == :error, number, "merged_rows", :unknown)
      |> add_error(Ecto.UUID.cast(row["item_uuid"]) == :error, number, "item_uuid", :invalid)
      |> add_error(field_error(quantity), number, "quantity")
      |> add_error(field_error(package_size), number, "package_size")

    if errors == [] do
      {:ok,
       %{
         row: number,
         merged_rows: merged,
         proposed: merge_proposed(proposed, merged, proposal),
         item_uuid: row["item_uuid"],
         quantity: elem(quantity, 1),
         package_size: elem(package_size, 1),
         action: row["action"]
       }}
    else
      {:error, errors}
    end
  end

  defp check_row(_row, _proposal), do: {:error, [%{row: nil, field: "row", error: :unknown}]}

  # The other rows of the proposal a row of the table stands for, when the
  # table merged rows of one item: numbers of the proposal, other than the
  # row's own.
  defp merged_rows(nil, _number, _proposal), do: []

  defp merged_rows(numbers, number, proposal) when is_list(numbers) do
    merged = Enum.map(numbers, &whole/1)

    if Enum.all?(merged, &(is_integer(&1) and &1 != number and Map.has_key?(proposal, &1))),
      do: merged,
      else: :error
  end

  defp merged_rows(_numbers, _number, _proposal), do: :error

  # The objects of every row a merged row stands for count together.
  defp merge_proposed(proposed, [], _proposal), do: proposed

  defp merge_proposed(proposed, merged, proposal) do
    objects = Enum.flat_map([proposed | Enum.map(merged, &proposal[&1])], &(&1["objects"] || []))
    Map.put(proposed, "objects", objects)
  end

  # A row of the proposal applied once: as a row of its own or merged into
  # another.
  defp repeated_numbers(rows) do
    rows
    |> Enum.flat_map(fn row -> Enum.map([row.row | row.merged_rows], &{&1, row.row}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn
      {_number, [_one]} -> []
      {_number, [_ | more]} -> Enum.map(more, &%{row: &1, field: "row", error: :repeated})
    end)
    |> Enum.uniq()
  end

  defp add_error(errors, false, _row, _field, _error), do: errors

  defp add_error(errors, true, row, field, error),
    do: errors ++ [%{row: row, field: field, error: error}]

  defp add_error(errors, nil, _row, _field), do: errors

  defp add_error(errors, error, row, field),
    do: errors ++ [%{row: row, field: field, error: error}]

  # Blank or unreadable is an error of the field, never 0; a negative is an
  # error too, never cut to 0. `parse_decimal/2` also refuses a NaN, an
  # infinity and a magnitude of 10^12 or more, a Decimal given as is too.
  defp quantity(value) do
    case Number.parse_decimal(value, min: 0) do
      {:ok, qty} -> {:ok, qty}
      {:error, :below_min} -> {:error, :negative}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  defp package_size(value) when value in [nil, ""], do: {:ok, nil}

  defp package_size(value) do
    case Number.parse_decimal(value, min: 0) do
      {:ok, size} -> if Decimal.gt?(size, 0), do: {:ok, size}, else: {:error, :invalid}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  defp field_error({:ok, _value}), do: nil
  defp field_error({:error, error}), do: error

  defp whole(value) when is_integer(value), do: value

  defp whole(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp whole(_value), do: nil

  defp repeated(rows, key, field) do
    rows
    |> Enum.group_by(&Map.fetch!(&1, key))
    |> Enum.flat_map(fn
      {_value, [_one]} -> []
      {_value, [_ | more]} -> Enum.map(more, &%{row: &1.row, field: field, error: :repeated})
    end)
  end

  defp check_items(rows) do
    items =
      rows
      |> Enum.map(& &1.item_uuid)
      |> Catalogue.list_items_by_uuids()
      |> Enum.filter(&(&1.status == "active"))
      |> Map.new(&{&1.uuid, &1})

    case Enum.reject(rows, &Map.has_key?(items, &1.item_uuid)) do
      [] ->
        {:ok, items}

      missing ->
        {:error,
         {:invalid_rows,
          Enum.map(missing, &%{row: &1.row, field: "item_uuid", error: :not_active})}}
    end
  end

  # The stock of the touched items on the document's warehouse, read in this
  # transaction - never the page's copy.
  defp stock(repo, item_uuids, location_uuid) do
    item_uuids
    |> StockLedger.stock_for_items_at_location(location_uuid, repo)
    |> Map.new(&{&1.item_uuid, &1})
  end

  defp apply_rows(rows, items, stock, socket_lines, run, locale) do
    Enum.reduce_while(rows, {:ok, socket_lines, []}, fn row, {:ok, lines, applied} ->
      case apply_row(row, items[row.item_uuid], stock[row.item_uuid], lines, run, locale) do
        {:ok, lines, entry} -> {:cont, {:ok, lines, applied ++ [entry]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_row(row, item, stock_row, lines, run, locale) do
    stock_qty = stock_row && stock_row.quantity

    with {:ok, index, line} <- find_line(lines, row) do
      %{default: default, actions: actions} = Lines.choices(line, stock_qty, run.place_label)
      action = row.action || default

      cond do
        action not in actions ->
          {:error, {:invalid_rows, [%{row: row.row, field: "action", error: :not_allowed}]}}

        line && is_nil(Lines.decimal(line["counted_quantity"])) ->
          {:error, {:invalid_rows, [%{row: row.row, field: "line", error: :invalid}]}}

        true ->
          part = %{
            "run_uuid" => run.uuid,
            "place" => run.place_label,
            "qty" => row.quantity,
            "basis" => basis(row, item, run.place_label)
          }

          updated = Lines.apply(line, action, part, new_line(item, stock_row, locale), stock_qty)
          lines = if index, do: List.replace_at(lines, index, updated), else: lines ++ [updated]

          {:ok, lines,
           %{
             row: row.row,
             merged_rows: row.merged_rows,
             item_uuid: item.uuid,
             action: action,
             quantity: row.quantity,
             previous: line && Lines.decimal(line["counted_quantity"]),
             counted: updated["counted_quantity"],
             stock: stock_qty
           }}
      end
    end
  end

  # The line of the item, if the tab has one; two lines of one item cannot
  # be told apart, so a row touching such an item is refused.
  defp find_line(lines, row) do
    case lines
         |> Enum.with_index()
         |> Enum.filter(fn {line, _} -> line["item_uuid"] == row.item_uuid end) do
      [] -> {:ok, nil, nil}
      [{line, index}] -> {:ok, index, line}
      _many -> {:error, {:invalid_rows, [%{row: row.row, field: "line", error: :repeated}]}}
    end
  end

  # A new line, as "Add item" builds one: the name in the page's language,
  # the stock's unit value, else the item's base price.
  defp new_line(item, stock_row, locale) do
    %{
      "item_uuid" => item.uuid,
      "name" => WarehouseBrowser.localized_name(item, locale),
      "sku" => item.sku,
      "category_uuid" => item.category_uuid,
      "catalogue_uuid" => item.catalogue_uuid,
      "unit" => item.unit,
      "counted_quantity" => Decimal.new(0),
      "unit_value" =>
        (stock_row && stock_row.unit_value) || StockLedger.to_decimal_or_nil(item.base_price)
    }
  end

  # "How it was counted": the formulas of the proposal when the quantity is
  # what they give for this item, otherwise the number the person typed.
  defp basis(row, item, place) do
    count = Proposal.recount(row.proposed, item.unit, row.package_size)

    text =
      if count["kind"] in ["counted", "measured"] and Decimal.eq?(count["quantity"], row.quantity),
        do: Enum.join(count["formulas"], ", "),
        else:
          dgettext("default", "entered by hand: %{quantity}",
            quantity: StockLedger.format_quantity(row.quantity)
          )

    case place do
      place when is_binary(place) and place != "" -> "#{place}: #{text}"
      _ -> text
    end
  end

  defp decisions(applied) do
    %{
      "applied_at" => DateTime.to_iso8601(InventoryAI.now()),
      "rows" =>
        Enum.map(applied, fn entry ->
          %{
            "row" => entry.row,
            "merged_rows" => entry.merged_rows,
            "item_uuid" => entry.item_uuid,
            "action" => entry.action,
            "quantity" => entry.quantity,
            "previous_counted_quantity" => entry.previous,
            "counted_quantity" => entry.counted,
            "stock" => entry.stock
          }
        end)
    }
  end

  defp summary(applied) do
    %{
      applied: length(applied),
      replaced: Enum.count(applied, &(&1.action in @replacing)),
      added: Enum.count(applied, &(&1.action in @adding)),
      new: Enum.count(applied, &(&1.action == "new")),
      below_stock: Enum.count(applied, &Lines.below_stock?(&1.counted, &1.stock))
    }
  end
end
