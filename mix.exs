defmodule Kuroneko.MixProject do
  use Mix.Project

  @app :kuroneko
  @version "0.3.0"
  @all_targets [:nano_kvm_go]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.20",
      archives: [nerves_bootstrap: "~> 1.17"],
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [{@app, release()}]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools, :ssl, :ssh],
      mod: {Kuroneko.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:logger_backends, "~> 1.0"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},
      {:muontrap, "~> 2.0"},
      sibling(:nano_kvm_go, "v0.4.0"),
      sibling(:kuroneko_gadget, "v0.5.0"),
      sibling(:axera_npu, "v0.2.0"),
      {:bandit, "~> 1.6"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:x509, "~> 0.8"},

      # The pages: Phoenix LiveView, styled with Tailwind CSS and daisyUI,
      # Heroicons; their CSS and JavaScript are built on the host
      {:phoenix, "~> 1.8.17"},
      {:phoenix_html, "~> 4.4"},
      {:phoenix_live_view, "~> 1.2.15"},
      {:lazy_html, "~> 0.1.16", only: :test},
      {:esbuild, "~> 0.10.1", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5.2", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.8.3",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      sibling(:nerves_system_nano_kvm_go, "v0.2.0",
        runtime: false,
        targets: :nano_kvm_go,
        nerves: [compile: true]
      )
    ]
  end

  # KURONEKO_DEPS_PATH=.. builds with the checkouts next to this one
  defp sibling(app, tag, opts \\ []) do
    case System.get_env("KURONEKO_DEPS_PATH") do
      nil -> {app, [github: "cocoa-xu/#{app}", tag: tag] ++ opts}
      dir -> {app, [path: Path.join(dir, "#{app}")] ++ opts}
    end
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://nerves-pack.hexdocs.pm/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []

  # The pages' CSS and JavaScript go into the firmware: compile first, for
  # the hooks that LiveView takes from the modules.
  defp aliases do
    [
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind kuroneko", "esbuild kuroneko"],
      "assets.deploy": ["compile", "tailwind kuroneko --minify", "esbuild kuroneko --minify"],
      firmware: ["assets.setup", "assets.deploy", "firmware"]
    ]
  end
end
