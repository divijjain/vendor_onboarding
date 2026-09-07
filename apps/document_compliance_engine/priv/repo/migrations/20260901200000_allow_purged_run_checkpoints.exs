defmodule DocumentComplianceEngine.Repo.Migrations.AllowPurgedRunCheckpoints do
  @moduledoc """
  `agent_checkpoints.run_checkpoints.reactor_state` becomes nullable so a
  finished checkpoint can keep its row while dropping its payload — see
  `Agent.Checkpoint.Repository.purge_payload/1`.

  Until now a resumed checkpoint kept everything it was created with,
  permanently: a serialized reactor (measured at ~14KB on a small fixture)
  and an `inputs` map holding the full text of every document in the job.
  For a `vendor_contract_w9` run that text contains the W-9's Tax ID in
  plaintext, in a column that — unlike `agent_runs.tax_id` — is not
  encrypted. Nothing reads either column again once the run has finished:
  the outcome is on `agent_runs`, and the reviewer's decision and the
  evidence they saw are on `review_decisions`.

  NULL here means exactly one thing — "this checkpoint has been resumed
  and its payload dropped" — which `Agent.Run.resume/3` now treats as a
  clean "already resumed" failure instead of deserializing nil.

  The down direction restores NOT NULL, which will fail if any purged row
  exists by then. Deliberate: inventing a placeholder `reactor_state` to
  make a rollback succeed would leave rows that look resumable and aren't.
  """

  use Ecto.Migration

  def up do
    alter table(:run_checkpoints, prefix: "agent_checkpoints") do
      modify :reactor_state, :binary, null: true
    end
  end

  def down do
    alter table(:run_checkpoints, prefix: "agent_checkpoints") do
      modify :reactor_state, :binary, null: false
    end
  end
end
