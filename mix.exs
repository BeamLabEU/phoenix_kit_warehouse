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
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Warehouse module for PhoenixKit — inventory, stock, goods receipts/issues.",
      package: package(),
      dialyzer: [
        plt_add_apps: [
          :phoenix_kit,
          :phoenix_kit_billing,
          :phoenix_kit_catalogue,
          :phoenix_kit_comments,
          :phoenix_kit_locations
        ]
      ],
      name: "PhoenixKitWarehouse",
      source_url: @source_url,
      docs: docs(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [
        :logger,
        :phoenix_kit,
        :phoenix_kit_billing,
        :phoenix_kit_catalogue,
        :phoenix_kit_comments,
        :phoenix_kit_locations
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      # Schema is applied by test/test_helper.exs on every `mix test` run via
      # PhoenixKit.Migration.ensure_current/2 plus the module's own
      # migration_module/0 — so there is no `ecto.migrate` step here.
      "test.setup": ["ecto.create --quiet -r PhoenixKitWarehouse.Test.Repo"],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitWarehouse.Test.Repo",
        "test.setup"
      ],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "quality.ci"
      ]
    ]
  end

  # phoenix_kit (and sibling phoenix_kit_* deps) resolve from Hex by default.
  # For cross-repo work against a local checkout — e.g. an unpublished core
  # change — export `<APP>_PATH` (e.g. `PHOENIX_KIT_PATH=../phoenix_kit`) and
  # Mix swaps the Hex pin for a `path:` + `override: true` dep at resolve time.
  # Unset => the published pin, so `mix hex.publish` and CI resolve unchanged.
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
      # The warehouse DB tables ship in core migration V140, published in
      # phoenix_kit 1.7.182 — so the module needs at least that core release.
      # hackney 4.x override mirrors core: stripity_stripe/ex_aws_sqs still pin 1.x,
      # but core (>= 1.7.189) requires hackney ~> 4.0 and overrides only apply from the root project.
      {:hackney, "~> 4.0", override: true},
      pk_dep(:phoenix_kit, "~> 1.7.189"),
      # Sibling PhoenixKit modules the warehouse UI/contexts build on:
      # comments embeds, catalogue products, locations, and billing currency.
      pk_dep(:phoenix_kit_billing, "~> 0.5"),
      pk_dep(:phoenix_kit_catalogue, "~> 0.10"),
      pk_dep(:phoenix_kit_comments, "~> 0.2"),
      pk_dep(:phoenix_kit_locations, "~> 0.2"),
      {:phoenix_live_view, "~> 1.1"},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitWarehouse",
      source_ref: @version
    ]
  end
end
