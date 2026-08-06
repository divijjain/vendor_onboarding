defmodule VendorOnboarding.Onboardings do
  @moduledoc """
  Public API for the onboarding-ingestion domain. `defdelegate` only — no
  logic here. Owns the `onboardings` table: what came in, and the
  aggregate status. See `VendorOnboarding.AgentRuns` for the agent's
  extracted/validated output.
  """

  alias VendorOnboarding.Onboardings.Actions.{IngestWebhook, ListWithLatestRun}
  alias VendorOnboarding.Onboardings.Repository

  defdelegate get_onboarding(id), to: Repository, as: :get
  defdelegate get_onboarding!(id), to: Repository, as: :get!
  defdelegate list_onboardings(opts \\ []), to: Repository, as: :list
  defdelegate list_onboardings_with_latest_run(opts \\ []), to: ListWithLatestRun, as: :run
  defdelegate reload_onboarding_row(id), to: ListWithLatestRun, as: :reload
  defdelegate update_status(id, status), to: Repository
  defdelegate ingest_webhook(raw_payload), to: IngestWebhook, as: :call
end
