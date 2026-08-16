defmodule DocumentComplianceEngine.Repo.Migrations.TypeValidationRulesAndAddInvoice do
  use Ecto.Migration

  # `vendor_contract_w9`'s seeded `validation_rules` predates the agent
  # pipeline actually reading this table (see the generalize_onboardings_
  # to_document_jobs migration) — it only had bare `{"tool": ...}` entries,
  # with no `"type"` discriminator and no `"field"` reference, and never
  # covered the entity-match check at all. Reshapes it to the typed rule
  # format `Agent.Checks.validate_all/2` now interprets, and seeds a second,
  # genuinely different document type (`invoice`: one document, no
  # entity-match, reusing the existing sanctions-screen tool) to prove the
  # pipeline generalizes rather than just reformatting one case's config.

  def change do
    execute(
      """
      UPDATE document_types
      SET validation_rules = ARRAY[
        '{"type": "entity_match", "fields": [{"role": "contract", "name": "company_name"}, {"role": "w9", "name": "company_name"}]}'::jsonb,
        '{"type": "mcp_tool", "tool": "validate_tax_id", "field": {"role": "w9", "name": "tax_id"}}'::jsonb,
        '{"type": "mcp_tool", "tool": "screen_vendor", "field": {"role": "contract", "name": "company_name"}}'::jsonb
      ]
      WHERE slug = 'vendor_contract_w9'
      """,
      """
      UPDATE document_types
      SET validation_rules = ARRAY['{"tool": "validate_tax_id"}'::jsonb, '{"tool": "screen_vendor"}'::jsonb]
      WHERE slug = 'vendor_contract_w9'
      """
    )

    execute(
      """
      INSERT INTO document_types (slug, name, extraction_schema, validation_rules, inserted_at, updated_at)
      VALUES (
        'invoice',
        'Vendor invoice',
        '{"invoice": {"vendor_name": "string", "invoice_number": "string", "amount": "string", "due_date": "string"}}',
        ARRAY['{"type": "mcp_tool", "tool": "screen_vendor", "field": {"role": "invoice", "name": "vendor_name"}}'::jsonb],
        now(),
        now()
      )
      """,
      "DELETE FROM document_types WHERE slug = 'invoice'"
    )
  end
end
