defmodule PhoenixKitWarehouse.MixProject do
  use Mix.Project

  @version "0.3.2"
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
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true,
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
      # PhoenixKit.Migration.ensure_current/2 (including V144) — so there is
      # no `ecto.migrate` step here.
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
      # The transfers/min_stock tables ship in core migration V144
      # (renumbered from V143 at merge time), first published in
      # phoenix_kit 1.7.190 (1.7.189 tops out at V142).
      # 1.7.214+ required: Scope.can_access_admin_area?/1 (the rename of the
      # now-`@deprecated` Scope.admin?/1) — an older core has no such function,
      # so this is an UndefinedFunctionError at runtime, not a warning.
      # 1.7.231 is the floor: that release ships
      # `PhoenixKitWeb.Live.UrlState`, which 7 LiveView files in this
      # module `use`. Anything below it resolves a core with no such
      # module, and the failure surfaces in the consumer's build.
      # Core 2.x only. Keep this a TWO-segment `~> 2.0`: a three-segment
      # `~> 2.0.x` expands to `< 2.1.0` and would strand host resolution the
      # moment core ships 2.1 — the same failure the old `~> 1.7.231` pin had
      # against core 2.0.0, which is what PR #15 was opened to fix.
      pk_dep(:phoenix_kit, "~> 2.0"),
      # mdex_native (pulled in transitively through phoenix_kit's mdex dep)
      # builds from source when MDEX_NATIVE_BUILD=1 is set in the
      # environment; that path requires rustler itself, not just
      # rustler_precompiled. Same declaration as phoenix_kit's own mix.exs.
      {:rustler, ">= 0.0.0", optional: true},
      # Sibling PhoenixKit modules the warehouse UI/contexts build on:
      # comments embeds, catalogue products, locations, and billing currency.
      pk_dep(:phoenix_kit_billing, "~> 0.7"),
      pk_dep(:phoenix_kit_catalogue, "~> 0.13"),
      # 0.2.8 is the floor for the same reason `phoenix_kit` has one: six form
      # LiveViews `use PhoenixKitComments.Embed` (first shipped in 0.2.6, and a
      # `use` cannot be guarded), and `PhoenixKitWarehouse.Comments` calls
      # `subscribe/2`, `unsubscribe/2` and the list form of `count_comments/2`
      # — all three arrived in 0.2.8. `available?/0` only guards the module
      # being absent entirely, not an older one missing those functions.
      pk_dep(:phoenix_kit_comments, "~> 0.3"),
      pk_dep(:phoenix_kit_locations, "~> 0.4"),
      {:phoenix_live_view, "~> 1.1"},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # `Phoenix.LiveViewTest` parses HTML via `lazy_html` for `element/2`,
      # `render(view) =~ "..."`, etc. Test-only. Without it every LiveView
      # test raises "Phoenix LiveView requires lazy_html as a test dependency".
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitWarehouse",
      source_ref: @version
    ]
  end
end
