defmodule DocumentComplianceEngine.Repo.Migrations.AddSemanticDescriptions do
  @moduledoc """
  Semantic descriptions, at both levels a document type has one:

    - `document_types.description` — a new column, one paragraph saying
      what this kind of document *is* and what distinguishes it from a
      neighbouring type. Written to be read by a model, not only a human:
      this is the text a classifier will reason over when it has to pick
      one type out of the registry, so each one says what the document
      contains and what tells it apart, rather than restating the name.
    - a `"description"` alongside `"type"` in every `extraction_schema`
      field spec, which changes the field value from the bare type string
      to a map (`%{"type" => ..., "description" => ...}` — see
      `Agent.ExtractionSchema`). Structural, so this migration rewrites
      every existing row's schema wholesale.

  **A description says what a field means, never what it should look
  like.** This was learned the expensive way, from this migration: the
  first version of `tax_id`'s description said "written as two digits, a
  hyphen, then seven digits", and the eval corpus immediately caught
  `malformed-03` — whose W-9 states `123456789` with no hyphen — being
  extracted as `12-3456789`. The model reformatted the value to match the
  description, which overrode the prompt's "copy the value exactly as the
  document writes it" instruction and turned a correctly-extracted
  malformed value into an ungrounded one. Format belongs to the field's
  declared type and to `format`/`regex` rules, which check a value without
  ever telling the model what to produce.

  Field descriptions are written only where the field name genuinely
  underdetermines the value — `payment_terms`, `liability_clauses`,
  `due_date` (which of an invoice's dates is *the* one), `amount` (the
  total payable, not a line item or a subtotal). `company_name` and
  `invoice_number` are left with none rather than padded with a sentence
  restating the name; a description exists to resolve ambiguity, and one
  that doesn't is prompt noise on every future extraction.

  Reversible: the down direction restores the exact bare-string schemas
  the previous migration left, and drops the column.
  """

  use Ecto.Migration

  @contract_w9_typed """
  {
    "contract": {
      "company_name": {"type": "string"},
      "payment_terms": {
        "type": "string",
        "description": "The agreed schedule or conditions for payment, quoted as the contract states them — not an amount."
      },
      "liability_clauses": {
        "type": "string",
        "description": "The clause limiting or allocating liability between the parties, quoted from the contract body."
      }
    },
    "w9": {
      "company_name": {"type": "string"},
      "tax_id": {
        "type": "string",
        "description": "The taxpayer identification number this W-9 states for the entity, copied exactly as the form writes it."
      }
    }
  }
  """

  @contract_w9_bare """
  {"contract": {"company_name": "string", "payment_terms": "string", "liability_clauses": "string"}, "w9": {"company_name": "string", "tax_id": "string"}}
  """

  @invoice_typed """
  {
    "invoice": {
      "vendor_name": {
        "type": "string",
        "description": "The name of the business issuing the invoice and being paid — not the customer being billed."
      },
      "invoice_number": {"type": "string"},
      "amount": {
        "type": "monetary_amount",
        "description": "The total amount payable on this invoice, including any tax — not a line-item price or a pre-tax subtotal."
      },
      "due_date": {
        "type": "date",
        "description": "The date payment is due, which may differ from the invoice's issue date."
      }
    }
  }
  """

  @invoice_bare """
  {"invoice": {"vendor_name": "string", "invoice_number": "string", "amount": "monetary_amount", "due_date": "date"}}
  """

  @contract_w9_description """
  A vendor onboarding bundle: a signed services or supply agreement between a \
  business and a vendor, paired with the vendor's IRS Form W-9. The contract \
  states the parties, payment terms and liability provisions; the W-9 states \
  the vendor's legal name and Employer Identification Number for tax \
  reporting. Distinguished from a single-document type by arriving as two \
  documents that must name the same legal entity.
  """

  @invoice_description """
  A commercial invoice issued by a vendor requesting payment for goods or \
  services already supplied. Names the issuing vendor, an invoice number, a \
  total amount payable and a due date. Distinguished from a purchase order by \
  requesting payment for work already done rather than ordering work not yet \
  done, and from a receipt by being unpaid at the time of issue.
  """

  def up do
    alter table(:document_types) do
      add :description, :text
    end

    set_schema("vendor_contract_w9", @contract_w9_typed)
    set_schema("invoice", @invoice_typed)

    set_description("vendor_contract_w9", @contract_w9_description)
    set_description("invoice", @invoice_description)
  end

  def down do
    set_schema("vendor_contract_w9", @contract_w9_bare)
    set_schema("invoice", @invoice_bare)

    alter table(:document_types) do
      remove :description
    end
  end

  defp set_schema(slug, schema) do
    execute("""
    UPDATE document_types
    SET extraction_schema = '#{String.replace(schema, "'", "''")}'::jsonb
    WHERE slug = '#{slug}'
    """)
  end

  defp set_description(slug, description) do
    execute("""
    UPDATE document_types
    SET description = '#{String.replace(String.trim(description), "'", "''")}'
    WHERE slug = '#{slug}'
    """)
  end
end
