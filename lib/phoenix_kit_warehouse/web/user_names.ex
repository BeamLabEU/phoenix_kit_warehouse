defmodule PhoenixKitWarehouse.Web.UserNames do
  @moduledoc """
  Resolves the user uuids a warehouse document carries (`created_by_uuid`,
  `performed_by_uuid`) into names fit for a list column.

  Every document list wants the same two columns — who created it and who is
  responsible for it — and each of the six lists enriches its own rows, so
  without a shared step each of them would either repeat the same query or,
  worse, call `Auth.get_user/1` once per row. `resolve/2` collects the uuids of
  a whole page first and fetches them in ONE `get_users_by_uuids/1` call.

  A uuid with no matching user (a deleted account, a document imported from
  elsewhere) is not an error: it renders as a short uuid stub so the column
  still says "somebody", instead of blanking out and reading like "nobody".
  """

  alias PhoenixKit.Users.Auth

  @doc """
  Builds a `%{uuid => display name}` map for a list of documents.

  `fields` names the uuid-carrying fields to collect; the default covers the
  creator/responsible pair every warehouse document schema declares.
  """
  def resolve(docs, fields \\ [:created_by_uuid, :performed_by_uuid]) do
    docs
    |> Enum.flat_map(fn doc -> Enum.map(fields, &Map.get(doc, &1)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Auth.get_users_by_uuids()
    |> Map.new(fn user -> {user.uuid, display_name(user)} end)
  end

  @doc """
  Looks one uuid up in a `resolve/2` map. `nil` (the field was never set)
  renders as an em dash — the same "no value" mark the lists use elsewhere.
  """
  def label(_names, nil), do: "—"

  def label(names, uuid) do
    Map.get(names, uuid) || stub(uuid)
  end

  defp display_name(user) do
    full = [user.first_name, user.last_name] |> Enum.reject(&blank?/1) |> Enum.join(" ")

    cond do
      full != "" -> full
      not blank?(user.username) -> user.username
      not blank?(user.email) -> user.email
      true -> stub(user.uuid)
    end
  end

  defp stub(uuid) when is_binary(uuid), do: String.slice(uuid, 0, 8) <> "…"
  defp stub(_), do: "—"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
