defmodule DocumentComplianceEngine.Umbrella.MixProject do
  use Mix.Project

  @moduledoc """
  Coordinates the three apps under `apps/` for visual/repo-layout purposes
  only — each app stays fully independent (own `deps_path`/`build_path`/
  `config_path`/`lockfile`, own `precommit` alias), a deliberate departure
  from a standard shared-dependency umbrella. See `CONTEXT.md`'s dated
  entry on the umbrella restructuring for why.
  """

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end
end
