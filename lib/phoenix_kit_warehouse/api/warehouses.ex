defmodule PhoenixKitWarehouse.API.Warehouses do
  @moduledoc """
  Warehouse locations as the API tools see them: the list for
  `warehouse.list_locations`, and the check that a `location_id` (or the
  default) is a place stock may be read from or written to.

  A location is a *warehouse* when it carries the configured warehouse
  location type (`StockLedger.list_warehouses/0`). Stock is written only to
  `active` warehouses; it can be read from any.
  """

  alias PhoenixKitWarehouse.API.Refs
  alias PhoenixKitWarehouse.StockLedger

  @default_setting "warehouse_default_location_uuid"

  @type error :: %{path: String.t(), code: String.t(), message: String.t()}

  @doc """
  The warehouses, the default one, and how far the module is set up
  (`"ready"`, `"needs_location_type"`, `"needs_locations"`,
  `"needs_default_location"`: the steps of `StockLedger.setup_status/0`).
  """
  @spec list() :: %{
          locations: [map()],
          default_location_id: String.t() | nil,
          setup: String.t()
        }
  def list do
    default = StockLedger.default_location_uuid()
    warehouses = StockLedger.list_warehouses() || []

    %{
      locations:
        Enum.map(warehouses, fn location ->
          %{
            "id" => location.uuid,
            "name" => location.name,
            "status" => location.status,
            "default" => location.uuid == default
          }
        end),
      default_location_id: if(Enum.any?(warehouses, &(&1.uuid == default)), do: default),
      setup: setup_label(StockLedger.setup_status())
    }
  end

  defp setup_label(:ready), do: "ready"
  defp setup_label({:needs, step}), do: "needs_" <> Atom.to_string(step)

  @doc """
  Checks `location_id` (`nil` = the default warehouse) and returns its
  canonical UUID. `mode` is `:read` or `:write`; only `:write` refuses an
  inactive location.
  """
  @spec resolve(term(), :read | :write) :: {:ok, String.t()} | {:error, error()}
  def resolve(location_id, mode) when mode in [:read, :write] do
    with {:ok, wanted} <- wanted(location_id),
         {:ok, warehouses} <- warehouses(),
         {:ok, location} <- find(warehouses, wanted, location_id) do
      writable(location, mode, location_id)
    end
  end

  defp wanted(nil) do
    case StockLedger.default_location_uuid() do
      nil ->
        {:error,
         error(
           "No default warehouse location is set. Pass location_id, or choose a default " <>
             "warehouse in the Warehouse settings (setting #{@default_setting})."
         )}

      uuid ->
        {:ok, uuid}
    end
  end

  defp wanted(id) when is_binary(id) do
    case Refs.cast_uuid(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error("location_id must be a UUID.")}
    end
  end

  defp wanted(_other), do: {:error, error("location_id must be a UUID.")}

  defp warehouses do
    case StockLedger.list_warehouses() do
      nil ->
        {:error,
         error(
           "The warehouse location type is not configured. Choose it in the Warehouse settings."
         )}

      list ->
        {:ok, list}
    end
  end

  defp find(warehouses, wanted, location_id) do
    case Enum.find(warehouses, &(&1.uuid == wanted)) do
      nil when is_nil(location_id) ->
        {:error,
         error(
           "The default warehouse location is not a warehouse location. Choose a default " <>
             "warehouse in the Warehouse settings (setting #{@default_setting})."
         )}

      nil ->
        {:error,
         error(
           "location_id is not a warehouse location. List them with warehouse.list_locations."
         )}

      location ->
        {:ok, location}
    end
  end

  defp writable(location, :read, _location_id), do: {:ok, location.uuid}
  defp writable(%{status: "active"} = location, :write, _location_id), do: {:ok, location.uuid}

  defp writable(_inactive, :write, location_id) do
    subject = if is_nil(location_id), do: "The default warehouse location", else: "location_id"
    {:error, error("#{subject} is inactive; stock cannot be written there.")}
  end

  defp error(message), do: %{path: "location_id", code: "validation_failed", message: message}
end
