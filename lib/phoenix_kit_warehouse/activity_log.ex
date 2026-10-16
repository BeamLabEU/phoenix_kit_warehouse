defmodule PhoenixKitWarehouse.ActivityLog do
  @moduledoc """
  Single entry point for `warehouse` module activities.

  Wraps `PhoenixKit.Activity.log/1`, swallows errors, and respects the
  `:inventory_activity_logging` runtime kill switch.
  """

  require Logger
  alias PhoenixKitWarehouse.GoodsIssue
  alias PhoenixKitWarehouse.GoodsReceipt
  alias PhoenixKitWarehouse.InventoryDocument
  alias PhoenixKitWarehouse.Transfer

  @module_key "warehouse"

  @doc false
  def module_key, do: @module_key

  @doc "Logs the creation of an inventory document."
  def log_created(%InventoryDocument{} = doc, opts) do
    log(
      %{
        action: "warehouse.inventory.created",
        resource_type: "inventory_document",
        resource_uuid: doc.uuid,
        metadata: base_metadata(doc)
      },
      opts
    )
  end

  @doc "Logs a draft save with a compact summary of changed fields."
  def log_draft_saved(%InventoryDocument{} = doc, changes, opts) do
    log(
      %{
        action: "warehouse.inventory.draft_saved",
        resource_type: "inventory_document",
        resource_uuid: doc.uuid,
        metadata: Map.merge(base_metadata(doc), %{"changes" => stringify_changes(changes)})
      },
      opts
    )
  end

  @doc """
  Logs the posting of an inventory document, a goods receipt or a goods
  issue.

  Options: `:actor` (a map with `:uuid`), `:actor_uuid`, `:mode` (with an
  `:actor` and no `:mode` the entry is `"manual"`, a hand edit; the API
  passes `"auto"`), and `:metadata` - a map merged into the entry's
  metadata (the API passes `via`, `key_prefix`, `request_id`, `tool`, and
  `approved_by_uuid` when there is one). Like every entry of this module it
  follows the `:inventory_activity_logging` switch and swallows write errors.
  """
  def log_posted(%InventoryDocument{} = doc, opts) do
    log(
      %{
        action: "warehouse.inventory.posted",
        resource_type: "inventory_document",
        resource_uuid: doc.uuid,
        metadata: base_metadata(doc)
      },
      opts
    )
  end

  def log_posted(%GoodsReceipt{} = doc, opts) do
    log(
      %{
        action: "warehouse.goods_receipt.posted",
        resource_type: "goods_receipt",
        resource_uuid: doc.uuid,
        metadata: base_metadata(doc)
      },
      opts
    )
  end

  def log_posted(%GoodsIssue{} = doc, opts) do
    log(
      %{
        action: "warehouse.goods_issue.posted",
        resource_type: "goods_issue",
        resource_uuid: doc.uuid,
        metadata: base_metadata(doc)
      },
      opts
    )
  end

  @doc "Logs a content correction with a compact summary of changed fields."
  def log_corrected(%InventoryDocument{} = doc, changes, opts) do
    log(
      %{
        action: "warehouse.inventory.corrected",
        resource_type: "inventory_document",
        resource_uuid: doc.uuid,
        metadata: Map.merge(base_metadata(doc), %{"changes" => stringify_changes(changes)})
      },
      opts
    )
  end

  @doc "Logs a repost (re-application of stock quantities)."
  def log_reposted(%InventoryDocument{} = doc, opts) do
    log(
      %{
        action: "warehouse.inventory.reposted",
        resource_type: "inventory_document",
        resource_uuid: doc.uuid,
        metadata: base_metadata(doc)
      },
      opts
    )
  end

  @doc """
  Logs a responsibility change (created_by / performed_by).

  `changes` is a map with optional keys `:created_by` and `:performed_by`,
  each carrying a `{from, to}` tuple of UUID strings (or nil).

  Example:
      %{created_by: {"old-uuid", "new-uuid"}, performed_by: {nil, "new-uuid"}}
  """
  def log_responsibility_changed(%InventoryDocument{} = doc, changes, opts)
      when is_map(changes) do
    responsibility_meta =
      changes
      |> Map.take([:created_by, :performed_by])
      |> Map.new(fn {field, {from, to}} ->
        {to_string(field), %{"from" => stringify(from), "to" => stringify(to)}}
      end)

    log(
      %{
        action: "warehouse.inventory.responsibility_changed",
        resource_type: "inventory_document",
        resource_uuid: doc.uuid,
        metadata: Map.merge(base_metadata(doc), responsibility_meta)
      },
      opts
    )
  rescue
    e ->
      Logger.warning(
        "[Warehouse.ActivityLog] log_responsibility_changed error: #{Exception.message(e)}"
      )

      :ok
  end

  @doc "Logs the cancellation of a transfer."
  def log_transfer_cancelled(%Transfer{} = transfer, opts) do
    log(
      %{
        action: "warehouse.transfer.cancelled",
        resource_type: "transfer",
        resource_uuid: transfer.uuid,
        metadata: base_metadata(transfer)
      },
      opts
    )
  end

  ## Internals

  defp log(attrs, opts) do
    if enabled?() and Code.ensure_loaded?(PhoenixKit.Activity) do
      do_log(attrs, opts)
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("[Warehouse.ActivityLog] log error: #{log_error(e, opts)}")
      :ok
  end

  # An entry with API metadata logs only the kind of the exception: its message
  # can quote the metadata, which carries values of an API request. Every other
  # entry keeps the message.
  defp log_error(e, opts) do
    case Keyword.get(opts, :metadata) do
      metadata when metadata in [nil, %{}] -> Exception.message(e)
      _metadata -> inspect(e.__struct__)
    end
  end

  defp do_log(attrs, opts) do
    actor = Keyword.get(opts, :actor)

    base = %{
      module: @module_key,
      mode: Keyword.get(opts, :mode) || default_mode(actor),
      actor_uuid: actor_uuid(opts)
    }

    extra = Keyword.get(opts, :metadata, %{})
    attrs = Map.update(attrs, :metadata, extra, &Map.merge(&1, extra))

    PhoenixKit.Activity.log(Map.merge(base, attrs))
    :ok
  end

  defp enabled?,
    do: Application.get_env(:phoenix_kit_warehouse, :inventory_activity_logging, true)

  defp default_mode(nil), do: "auto"
  defp default_mode(_), do: "manual"

  defp actor_uuid(opts) do
    case Keyword.get(opts, :actor) do
      nil -> Keyword.get(opts, :actor_uuid)
      %{uuid: uuid} -> uuid
    end
  end

  defp base_metadata(%InventoryDocument{number: number}) do
    %{"number" => stringify(number)}
  end

  defp base_metadata(%Transfer{number: number}) do
    %{"number" => stringify(number)}
  end

  defp base_metadata(%GoodsReceipt{number: number, external_ref: external_ref}) do
    %{"number" => stringify(number), "external_ref" => stringify(external_ref)}
  end

  defp base_metadata(%GoodsIssue{number: number, external_ref: external_ref, reason: reason}) do
    %{
      "number" => stringify(number),
      "external_ref" => stringify(external_ref),
      "reason" => stringify(reason)
    }
  end

  defp stringify_changes(changes) when is_map(changes) do
    Map.new(changes, fn
      {field, %{from: f, to: t}} ->
        {to_string(field), %{"from" => stringify(f), "to" => stringify(t)}}

      {field, %{"from" => f, "to" => t}} ->
        {to_string(field), %{"from" => stringify(f), "to" => stringify(t)}}

      {field, value} ->
        {to_string(field), stringify(value)}
    end)
  end

  defp stringify_changes(changes) when is_list(changes) do
    Map.new(changes, fn {field, value} -> {to_string(field), stringify(value)} end)
  end

  defp stringify(nil), do: ""
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: to_string(v)
end
