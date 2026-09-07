defmodule DocumentComplianceEngine.Repo.Migrations.TypeExtractionSchemaFields do
  @moduledoc """
  `extraction_schema`'s field types have been the literal `"string"` for
  every field of every document type since the table was first seeded —
  the value was structural (`Extraction` pattern-matched it), never a real
  declaration. Now that `Agent.FieldTypes` is a genuine vocabulary that
  `Extraction.extract_all/3` validates and prompts from, this retypes the
  fields that aren't free text.

  Only `invoice` has any: `amount` is a monetary amount and `due_date` is a
  date. `amount` was typed `number` first; the scanned eval fixtures write
  it `"$1,275.00"` (the plain-text ones write `"1,000.00"`), which a bare
  number check rejects — a false "invalid" on a perfectly good invoice.
  `FormatValidators.monetary_amount` exists because of that, and this is
  the type that names it.

  Every `vendor_contract_w9` field genuinely is free text and stays `"string"` — `company_name`, `payment_terms` and
  `liability_clauses` obviously so, and `tax_id` deliberately: an EIN is an
  identifier scheme, not a way of writing a value, so it stays typed as
  text with the sharper checks where they already live (the EIN regex
  pre-filter in `Extraction`, the `validate_tax_id` MCP rule in `Checks`).
  See `FieldTypes`' moduledoc for that split.

  Data-only and reversible: the column, its shape (`role => field => type`)
  and every field name are untouched, so a rollback restores the prior
  all-`"string"` config exactly.
  """

  use Ecto.Migration

  def change do
    execute(
      """
      UPDATE document_types
      SET extraction_schema = '{"invoice": {"vendor_name": "string", "invoice_number": "string", "amount": "monetary_amount", "due_date": "date"}}'
      WHERE slug = 'invoice'
      """,
      """
      UPDATE document_types
      SET extraction_schema = '{"invoice": {"vendor_name": "string", "invoice_number": "string", "amount": "string", "due_date": "string"}}'
      WHERE slug = 'invoice'
      """
    )
  end
end
