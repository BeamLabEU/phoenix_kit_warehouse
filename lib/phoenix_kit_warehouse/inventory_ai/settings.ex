defmodule PhoenixKitWarehouse.InventoryAI.Settings do
  @moduledoc """
  The settings of the photo inventory (`PhoenixKit.Settings`, keys
  `warehouse_inventory_ai_*`):

    * `endpoint_uuid` - the AI endpoint that reads the photos; empty means the
      inventory button is not shown. Choosing it is choosing where money goes,
      so only a holder of the `ai` module (or an administrator) sets it - the
      settings page checks that, not this module;
    * `prompt_uuid` - the prompt the module owns, written by
      `PhoenixKitWarehouse.InventoryAI.Prompt`;
    * `max_photos` - photos in one batch (default 10);
    * `max_items` - the most catalogue lines one request may carry (default
      3000); a larger catalogue has to be narrowed first.

  A stored number that is not a whole number in range reads as the default.
  """

  alias PhoenixKit.Settings
  alias PhoenixKitWarehouse.InventoryAI.Prompt

  @endpoint_key "warehouse_inventory_ai_endpoint_uuid"
  @max_photos_key "warehouse_inventory_ai_max_photos"
  @max_items_key "warehouse_inventory_ai_max_items"

  @default_max_photos 10
  @default_max_items 3000

  # Upper bounds against a typo, not a product rule: ai takes at most 100 MB
  # of images per call, and a request of 20 000 lines is far past any
  # catalogue the whole-catalogue request is meant for.
  @max_photos_limit 30
  @max_items_limit 20_000

  @doc "The settings key holding the endpoint's uuid."
  @spec endpoint_key() :: String.t()
  def endpoint_key, do: @endpoint_key

  @doc "The settings key holding the photos-per-batch limit."
  @spec max_photos_key() :: String.t()
  def max_photos_key, do: @max_photos_key

  @doc "The settings key holding the catalogue-lines limit."
  @spec max_items_key() :: String.t()
  def max_items_key, do: @max_items_key

  @doc "The most photos the settings page accepts for `max_photos`."
  @spec max_photos_limit() :: pos_integer()
  def max_photos_limit, do: @max_photos_limit

  @doc "The most lines the settings page accepts for `max_items`."
  @spec max_items_limit() :: pos_integer()
  def max_items_limit, do: @max_items_limit

  @doc "The chosen AI endpoint's uuid, or `nil` while none is chosen."
  @spec endpoint_uuid() :: String.t() | nil
  def endpoint_uuid, do: read_text(@endpoint_key)

  @doc "Chooses the endpoint; `nil` or `\"\"` clears it. A value that is not a uuid is refused."
  @spec set_endpoint_uuid(String.t() | nil) :: :ok | {:error, :invalid | :failed}
  def set_endpoint_uuid(value) when value in [nil, ""], do: write(@endpoint_key, "")

  def set_endpoint_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> write(@endpoint_key, uuid)
      :error -> {:error, :invalid}
    end
  end

  def set_endpoint_uuid(_), do: {:error, :invalid}

  @doc "The uuid of the module's prompt, or `nil` before it is made."
  @spec prompt_uuid() :: String.t() | nil
  def prompt_uuid, do: read_text(Prompt.setting_key())

  @doc "Photos in one batch."
  @spec max_photos() :: pos_integer()
  def max_photos, do: read_int(@max_photos_key, @default_max_photos, @max_photos_limit)

  @doc "Sets the photos-per-batch limit (a whole number from 1 to `max_photos_limit/0`)."
  @spec set_max_photos(term()) :: :ok | {:error, :invalid | :failed}
  def set_max_photos(value), do: write_int(@max_photos_key, value, @max_photos_limit)

  @doc "Catalogue lines one request may carry."
  @spec max_items() :: pos_integer()
  def max_items, do: read_int(@max_items_key, @default_max_items, @max_items_limit)

  @doc "Sets the catalogue-lines limit (a whole number from 1 to `max_items_limit/0`)."
  @spec set_max_items(term()) :: :ok | {:error, :invalid | :failed}
  def set_max_items(value), do: write_int(@max_items_key, value, @max_items_limit)

  defp read_text(key) do
    case Settings.get_setting(key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp read_int(key, default, limit) do
    with value when is_binary(value) <- Settings.get_setting(key),
         {int, ""} <- Integer.parse(value),
         true <- int in 1..limit//1 do
      int
    else
      _ -> default
    end
  end

  defp write_int(key, value, limit) when is_integer(value) and value >= 1 and value <= limit,
    do: write(key, Integer.to_string(value))

  defp write_int(_key, _value, _limit), do: {:error, :invalid}

  # An empty value is stored as "", which the settings table refuses for a
  # row that does not exist yet: clearing what was never set is a no-op.
  defp write(key, "") do
    if read_text(key), do: store(key, ""), else: :ok
  end

  defp write(key, value), do: store(key, value)

  defp store(key, value) do
    case Settings.update_setting_with_module(key, value, PhoenixKitWarehouse.module_key()) do
      {:ok, _setting} -> :ok
      {:error, _changeset} -> {:error, :failed}
    end
  end
end
