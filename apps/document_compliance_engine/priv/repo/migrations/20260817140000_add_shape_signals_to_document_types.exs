defmodule DocumentComplianceEngine.Repo.Migrations.AddShapeSignalsToDocumentTypes do
  @moduledoc """
  `shape_signals`: an optional, per-role config (keyword list + minimum
  match count) that `Extraction.extract_all/3` checks *before* spending an
  LLM call on a role. A role with no shape_signals entry is unrestricted
  (opt-in, not required) — existing/future document types work unchanged
  until someone configures this.

  Backfills both existing document types so the check has real teeth from
  day one: a résumé or cover letter uploaded as an `invoice` or
  `vendor_contract_w9` document now fails this gate before extraction ever
  runs, rather than being extracted into fabricated fields (see
  CONTEXT.md's dated entry on the hallucination case this closes).
  """

  use Ecto.Migration

  def change do
    alter table(:document_types) do
      add :shape_signals, :map, null: false, default: %{}
    end

    execute(
      """
      UPDATE document_types
      SET shape_signals = '{
        "contract": {"keywords": ["agreement", "contract", "vendor", "payment terms", "liability"], "min_matches": 1},
        "w9": {"keywords": ["w-9", "taxpayer identification", "ein", "form w-9"], "min_matches": 1}
      }'::jsonb
      WHERE slug = 'vendor_contract_w9'
      """,
      "UPDATE document_types SET shape_signals = '{}'::jsonb WHERE slug = 'vendor_contract_w9'"
    )

    execute(
      """
      UPDATE document_types
      SET shape_signals = '{
        "invoice": {"keywords": ["invoice", "vendor", "amount", "due date", "bill to"], "min_matches": 2}
      }'::jsonb
      WHERE slug = 'invoice'
      """,
      "UPDATE document_types SET shape_signals = '{}'::jsonb WHERE slug = 'invoice'"
    )
  end
end
