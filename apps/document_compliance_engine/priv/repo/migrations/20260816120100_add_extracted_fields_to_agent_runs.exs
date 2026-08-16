defmodule DocumentComplianceEngine.Repo.Migrations.AddExtractedFieldsToAgentRuns do
  use Ecto.Migration

  # Generic, non-PII extracted-data column for document types with no
  # dedicated columns of their own (today: `invoice`). Deliberately a plain
  # map, not the encrypted type `tax_id` uses — Tax ID stays on its own
  # dedicated encrypted column always; nothing routes through here that
  # could carry it.
  def change do
    alter table(:agent_runs) do
      add :extracted_fields, :map, null: false, default: %{}
    end
  end
end
