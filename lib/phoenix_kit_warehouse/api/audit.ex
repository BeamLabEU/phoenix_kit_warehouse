defmodule PhoenixKitWarehouse.API.Audit do
  @moduledoc """
  The module's own Activity entry for a document posted through the API:
  the module that owns the data logs the change, with the actor. Core writes
  the request-level `api.request` entry separately.

  One entry per document, not per line. It is written with `mode: "auto"` so
  the Activity feed tells an API write from a hand edit (the module's default
  for a call with an actor is `"manual"`), and carries `approved_by_uuid`
  next to the actor when the operation was released from the approval queue.
  Like every entry of this module it follows the
  `:inventory_activity_logging` switch and never fails the document.
  """

  alias PhoenixKitWarehouse.ActivityLog

  @doc """
  Logs the posting of `doc` for the `request` map built by
  `PhoenixKitWarehouse.API.Write`, on behalf of the key in `ctx`.
  """
  @spec posted(map(), struct(), map()) :: :ok
  def posted(request, doc, ctx) do
    actor = Map.get(ctx, :actor) || %{}

    metadata =
      %{
        "via" => "api",
        "key_prefix" => Map.get(actor, :key_prefix),
        "request_id" => Map.get(ctx, :request_id),
        "approved_by_uuid" => Map.get(ctx, :approved_by_uuid),
        "tool" => tool(request.kind),
        "lines" => length(request.lines),
        "external_ref" => request.external_ref,
        "location_uuid" => request.location_uuid,
        "reason" => request.reason,
        "order_uuid" => request.order_uuid
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    ActivityLog.log_posted(doc,
      actor: %{uuid: Map.get(actor, :user_uuid)},
      mode: "auto",
      metadata: metadata
    )
  end

  defp tool(:receipt), do: "warehouse.receive_stock"
  defp tool(:inventory), do: "warehouse.set_stock"
  defp tool(:issue), do: "warehouse.issue_stock"
end
