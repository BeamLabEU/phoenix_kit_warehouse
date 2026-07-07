defmodule PhoenixKitWarehouse.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_warehouse"

  def project do
    [
      app: :phoenix_kit_warehouse,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Elixir 1.19 mix test requires explicit filters to know which test
      # files to load and which to ignore — without this it warns about
      # `test/support/*.ex` not matching either filter and skips running
      # the support modules through its loader, so `test_helper.exs` runs
      # before they're available.
      test_load_filters: [~r/_test\.exs$/],
      test_ignore_filters: [~r{^test/support/}],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Warehouse module for PhoenixKit — stock, stocktakes, internal orders, supplier orders, goods receipt, goods issue.",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      name: "PhoenixKitWarehouse",
      source_url: @source_url,
      docs: docs(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "quality.ci"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against
  # a local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit.
  # Unset => the published pin, so mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      pk_dep(:phoenix_kit, "~> 1.7 and >= 1.7.165"),
      pk_dep(:phoenix_kit_catalogue, "~> 0.10.0"),
      pk_dep(:phoenix_kit_locations, "~> 0.2.0"),
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitWarehouse",
      source_ref: @version
    ]
  end
end
