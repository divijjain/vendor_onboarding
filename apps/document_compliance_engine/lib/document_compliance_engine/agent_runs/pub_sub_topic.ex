defmodule DocumentComplianceEngine.AgentRuns.PubSubTopic do
  @moduledoc """
  Pure topic-name construction — no DB, no side effects. One organization
  per topic: `HandleAgentCallback` broadcasts a status change to every
  member of the document_job's organization, and `DashboardLive`/
  `ReviewLive` subscribe to their own organization's topic only. The
  topic is deliberately *shared* across every user in an organization —
  that's the whole point of the feature, a teammate should see another
  teammate's status updates — while still never crossing organization
  boundaries the way a single flat topic (this app's shape before
  per-account isolation, and again before organizations) would: every
  connected browser would otherwise see every other organization's status
  updates regardless of who's looking. The message must never reach
  another organization's LiveView process in the first place, not merely
  get filtered out after arrival.

  A document_job whose owner hasn't joined an organization yet has
  `organization_id: nil`, so `HandleAgentCallback` broadcasts on
  `for_organization(nil)` for it — harmless only because nobody can ever
  be a subscriber to that topic: every real LiveView subscriber has
  already passed `UserAuth`'s `:ensure_organization` on_mount hook, so
  `current_user.organization_id` is guaranteed non-nil at every real
  subscribe call site.
  """

  @spec for_organization(pos_integer() | nil) :: String.t()
  def for_organization(organization_id),
    do: "document_compliance_engine:organization:#{organization_id}"
end
