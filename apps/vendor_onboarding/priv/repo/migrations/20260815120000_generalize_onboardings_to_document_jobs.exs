defmodule VendorOnboarding.Repo.Migrations.GeneralizeOnboardingsToDocumentJobs do
  use Ecto.Migration

  # Data-model generalization: `onboardings` becomes `document_jobs`, gaining a
  # `document_type_slug` reference to a new `document_types` config table. The
  # agent pipeline itself is unchanged by this migration — every existing job
  # is backfilled onto a single "vendor_contract_w9" document type describing
  # today's fixed contract+W9 extraction, so this is additive, not a behavior
  # change. See CONTEXT.md's dated entry for the full rationale.

  def change do
    create table(:document_types) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :extraction_schema, :map, null: false, default: %{}
      add :validation_rules, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:document_types, [:slug])

    # Seed the one document type today's fixed pipeline actually implements,
    # before document_jobs.document_type_slug goes NOT NULL below — it needs
    # a real row to default onto.
    execute(
      """
      INSERT INTO document_types (slug, name, extraction_schema, validation_rules, inserted_at, updated_at)
      VALUES (
        'vendor_contract_w9',
        'Vendor contract + W-9 bundle',
        '{"contract": {"company_name": "string", "payment_terms": "string", "liability_clauses": "string"}, "w9": {"company_name": "string", "tax_id": "string"}}',
        ARRAY['{"tool": "validate_tax_id"}'::jsonb, '{"tool": "screen_vendor"}'::jsonb],
        now(),
        now()
      )
      """,
      "DELETE FROM document_types WHERE slug = 'vendor_contract_w9'"
    )

    rename table(:onboardings), to: table(:document_jobs)

    # Renaming a table does not rename its indexes/constraints in Postgres —
    # same gotcha the earlier vendor_onboardings -> onboardings rename hit.
    rename_index("onboardings_idempotency_key_index", "document_jobs_idempotency_key_index")
    rename_index("onboardings_status_index", "document_jobs_status_index")
    rename_index("onboardings_pkey", "document_jobs_pkey")

    alter table(:document_jobs) do
      add :document_type_slug, references(:document_types, column: :slug, type: :string),
        null: false,
        default: "vendor_contract_w9"
    end

    create index(:document_jobs, [:document_type_slug])

    rename table(:agent_runs), :vendor_onboarding_id, to: :document_job_id

    rename_index("agent_runs_vendor_onboarding_id_index", "agent_runs_document_job_id_index")
    rename_constraint("agent_runs_vendor_onboarding_id_fkey", "agent_runs_document_job_id_fkey")

    # The checkpoint table's Ecto schema (agent/checkpoint/schema/run_checkpoint.ex)
    # is application code, not a migration, so it was renamed straight to
    # document_job_id — this brings the physical column in `agent_checkpoints`
    # (its own schema, its own migration) in line with it.
    rename table(:run_checkpoints, prefix: "agent_checkpoints"), :onboarding_id,
      to: :document_job_id

    execute(
      "ALTER INDEX agent_checkpoints.run_checkpoints_onboarding_id_index RENAME TO run_checkpoints_document_job_id_index",
      "ALTER INDEX agent_checkpoints.run_checkpoints_document_job_id_index RENAME TO run_checkpoints_onboarding_id_index"
    )
  end

  defp rename_index(old_name, new_name) do
    execute(
      "ALTER INDEX #{old_name} RENAME TO #{new_name}",
      "ALTER INDEX #{new_name} RENAME TO #{old_name}"
    )
  end

  defp rename_constraint(old_name, new_name) do
    execute(
      "ALTER TABLE agent_runs RENAME CONSTRAINT #{old_name} TO #{new_name}",
      "ALTER TABLE agent_runs RENAME CONSTRAINT #{new_name} TO #{old_name}"
    )
  end
end
