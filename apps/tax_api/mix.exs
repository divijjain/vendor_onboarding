defmodule TaxApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :tax_api,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # Self-contained under the umbrella's apps/ — see the root mix.exs
      # moduledoc for why this isn't a standard shared-dependency umbrella.
      build_path: "_build",
      config_path: "config/config.exs",
      deps_path: "deps",
      lockfile: "mix.lock"
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TaxApi.Application, []}
    ]
  end

  defp deps do
    [
      {:hermes_mcp, "~> 0.14"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"}
    ]
  end

  defp aliases do
    [precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]]
  end
end
