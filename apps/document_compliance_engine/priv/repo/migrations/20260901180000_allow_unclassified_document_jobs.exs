defmodule DocumentComplianceEngine.Repo.Migrations.AllowUnclassifiedDocumentJobs do
  @moduledoc """
  `document_jobs.document_type_slug` becomes nullable, so a job can be
  ingested by a caller who doesn't know what they're sending — the whole
  point of `Agent.Classification`. The column is filled in by
  `AgentRuns.Actions.HandleAgentCallback` once the agent has classified
  the document, and stays null when it couldn't.

  The foreign key to `document_types` is untouched and still enforced:
  null means "not yet known", never "some type outside the registry".

  **The column default goes with the NOT NULL.** It was set to
  `'vendor_contract_w9'` when the column was added, back when that was the
  only type in existence and every row had to have it — harmless then,
  actively wrong now: an insert that omits the slug would silently be
  labelled a vendor contract rather than left for the classifier, which is
  precisely the confidently-wrong answer this feature exists to avoid.
  (Found by a test, not by reading: the first unclassified job came back
  already typed.)

  Irreversible in the strict sense — the down direction can only restore
  the NOT NULL constraint, which fails if any unclassified job exists by
  then. That is the honest behaviour: silently deleting or relabelling
  real rows to make a rollback succeed would be worse than the rollback
  refusing.
  """

  use Ecto.Migration

  def up do
    alter table(:document_jobs) do
      modify :document_type_slug, :string, null: true, default: nil
    end
  end

  def down do
    alter table(:document_jobs) do
      modify :document_type_slug, :string, null: false, default: "vendor_contract_w9"
    end
  end
end
