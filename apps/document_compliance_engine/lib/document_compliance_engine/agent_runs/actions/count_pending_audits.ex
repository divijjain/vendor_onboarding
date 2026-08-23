defmodule DocumentComplianceEngine.AgentRuns.Actions.CountPendingAudits do
  @moduledoc """
  Owner-scoped count for the dashboard's "Pending audits" health stat —
  reuses `ListPendingAudits`'s own owner-filtering rather than duplicating
  it, since the pending queue is small enough that counting the built
  list costs nothing extra.
  """

  alias DocumentComplianceEngine.AgentRuns.Actions.ListPendingAudits

  @spec call(pos_integer()) :: non_neg_integer()
  def call(owner_user_id) do
    owner_user_id |> ListPendingAudits.call() |> length()
  end
end
