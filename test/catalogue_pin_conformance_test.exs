defmodule PhoenixKitWarehouse.CataloguePinConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `:phoenix_kit_catalogue` requirement against drifting below the
  version the module is built against.

  Three LiveViews compile-time alias
  `PhoenixKitCatalogue.Web.Components.ItemSelectorModal`, which arrived in
  catalogue 0.18.0, and the photo inventory relies on the item type's
  `item_types` filter and the pack/kg/litre/m3 units, which arrived in
  0.46.0. A pin that still admits an older catalogue lets a host resolve
  one that this package cannot compile against, or one that offers
  services to the model.
  """

  @must_admit ["0.46.0", "0.48.1", "0.99.4"]
  @must_reject ["0.13.0", "0.18.0", "0.45.1", "1.0.0"]

  test "the :phoenix_kit_catalogue requirement admits 0.46+ and nothing below" do
    requirement = catalogue_requirement()

    assert match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           "`:phoenix_kit_catalogue` requirement #{inspect(requirement)} is not a valid requirement"

    for version <- @must_admit do
      assert Version.match?(version, requirement),
             "`:phoenix_kit_catalogue` requirement #{inspect(requirement)} rejects #{version}. " <>
               "Keep it a two-segment `~> 0.46` so 0.46+ resolves and 1.0 does not."
    end

    for version <- @must_reject do
      refute Version.match?(version, requirement),
             "`:phoenix_kit_catalogue` requirement #{inspect(requirement)} admits #{version}, " <>
               "which is outside the range this module compiles against."
    end
  end

  defp catalogue_requirement do
    resolved_requirement() || committed_requirement() ||
      flunk("""
      No version requirement found for `:phoenix_kit_catalogue`.

      Neither the resolved dep nor mix.exs carries one, which means a `path:`
      dep has been committed. Restore the published requirement.
      """)
  end

  defp resolved_requirement do
    Mix.Project.config()
    |> Keyword.get(:deps, [])
    |> Enum.find_value(fn
      {:phoenix_kit_catalogue, requirement} when is_binary(requirement) -> requirement
      {:phoenix_kit_catalogue, requirement, _opts} when is_binary(requirement) -> requirement
      _ -> nil
    end)
  end

  defp committed_requirement do
    case Regex.run(~r/:phoenix_kit_catalogue,\s*"([^"]+)"/, File.read!("mix.exs")) do
      [_full, requirement] -> requirement
      _ -> nil
    end
  end
end
