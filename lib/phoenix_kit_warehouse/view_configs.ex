defmodule PhoenixKitWarehouse.ViewConfigs do
  @moduledoc """
  Minimal per-user, per-scope view-preference store — the "smallest viable"
  replacement for `Andi.UserViewConfigs` (design doc, cross-dependency table).

  The original is backed by a dedicated `andi_user_view_configs` table
  (`user_uuid`, `scope`, `view_config` jsonb, unique on `(user_uuid, scope)`).
  A standalone package cannot add its own ad-hoc table outside the Track A
  versioned-migration convention (Plan 1 already shipped V136 without one —
  reopening it for a preferences table is out of scope). Instead this module
  stores the same `%{"columns" => [...], "active_filters" => [...]}` /
  `%{"stock_view" => "grouped" | "flat"}` shaped maps as a JSON-encoded blob
  in `phoenix_kit_settings`, one row per `(scope, user_uuid)` pair, keyed
  `"warehouse_view_config:<scope>:<user_uuid>"`.

  Trade-off accepted: `phoenix_kit_settings` is a flat key-value table with
  no secondary index on "all rows for this user" — fine at warehouse's scale
  (6 scopes × however many users actually customize columns), but this is
  not a pattern to reach for at higher fan-out. Flagged here, not treated as
  a blocker.
  """

  alias PhoenixKit.Settings

  @doc "Returns the user's saved view config for `scope`, or `%{}` if none exists yet."
  @spec get_view_config(binary(), String.t()) :: map()
  def get_view_config(user_uuid, scope) when is_binary(user_uuid) and is_binary(scope) do
    case Settings.get_setting(setting_key(user_uuid, scope), nil) do
      nil ->
        %{}

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end
    end
  end

  @doc """
  Merges `partial` into the user's existing view config for `scope` and
  persists the result. Keys absent from `partial` are preserved.
  """
  @spec merge_view_config(binary(), String.t(), map()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def merge_view_config(user_uuid, scope, partial)
      when is_binary(user_uuid) and is_binary(scope) and is_map(partial) do
    merged = Map.merge(get_view_config(user_uuid, scope), partial)

    case Settings.update_setting(setting_key(user_uuid, scope), Jason.encode!(merged)) do
      {:ok, _setting} -> {:ok, merged}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp setting_key(user_uuid, scope), do: "warehouse_view_config:#{scope}:#{user_uuid}"
end
