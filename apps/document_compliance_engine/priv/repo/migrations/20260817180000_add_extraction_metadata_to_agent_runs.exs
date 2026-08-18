defmodule DocumentComplianceEngine.Repo.Migrations.AddExtractionMetadataToAgentRuns do
  @moduledoc """
  Per-field confidence + source-location grounding, captured alongside
  the extracted value itself — see `Extraction`'s moduledoc for where the
  numbers come from (a real LLM call, a synthesized 1.0 for a
  regex-resolved field, or nil for a shape-gate-skipped one).

  Deliberately not extended to Tax ID: `Agent.Run.stringify_metadata/1`
  drops the `w9.tax_id` entry before it ever reaches this (unencrypted)
  column, the same exclusion `extracted_fields` already has — a
  regex-resolved Tax ID's synthesized source quote *is* the raw Tax ID.
  """

  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add :extraction_metadata, :map, null: false, default: %{}
    end
  end
end
