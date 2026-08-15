defmodule DocumentComplianceEngine.Agent.Evals.Fixtures do
  @moduledoc """
  20 synthetic vendor-document_job document pairs, deliberately structured
  into four buckets (not randomly generated) so the eval's bucket counts
  are auditable — see CONTEXT.md's evaluation design.

    10 clean               -> should auto-approve
     5 genuine mismatch    -> should flag (true positives)
     3 formatting-only     -> NOT a real mismatch (tests false-positive rate)
     2 missing/malformed   -> tests graceful degradation
  """

  defmodule Fixture do
    @moduledoc false
    @enforce_keys [:id, :bucket, :contract_text, :w9_text, :expected_decision]
    defstruct [
      :id,
      :bucket,
      :contract_text,
      :w9_text,
      :expected_decision,
      # nil where the check doesn't meaningfully apply (e.g. malformed docs).
      :expected_entity_match
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            bucket: String.t(),
            contract_text: String.t(),
            w9_text: String.t(),
            expected_decision: String.t(),
            expected_entity_match: boolean() | nil
          }
  end

  # --- 10 clean: contract and W-9 name match exactly, EIN well-formed ---
  @clean [
    {"Acme Corp", "12-3456789", "Net 30", "Standard indemnification clause."},
    {"Blue Ridge Logistics Inc.", "23-4567891", "Net 45",
     "Limited to fees paid in prior 12 months."},
    {"Summit Peak Freight LLC", "34-5678912", "Net 30",
     "Mutual indemnification for third-party claims."},
    {"Golden Gate Supplies Co.", "45-6789123", "Net 60", "Standard indemnification clause."},
    {"Northwind Traders Ltd.", "56-7891234", "Net 30", "Liability capped at contract value."},
    {"Pioneer Manufacturing Inc.", "67-8912345", "Net 45", "Standard indemnification clause."},
    {"Cascade Software Solutions LLC", "78-9123456", "Net 15",
     "Mutual indemnification for third-party claims."},
    {"Redwood Consulting Group", "89-1234567", "Net 30",
     "Limited to fees paid in prior 12 months."},
    {"Silverline Logistics Corp.", "90-2345678", "Net 30", "Liability capped at contract value."},
    {"Harborview Industries Inc.", "11-2233445", "Net 45", "Standard indemnification clause."}
  ]

  # --- 5 genuine mismatch: contract vendor name is a different legal entity than the W-9 ---
  @mismatch [
    {"Zenith Marketing Partners", "Apex Creative Group", "22-3344556"},
    {"TransGlobal Shipping Co.", "Coastal Freight Solutions", "33-4455667"},
    {"BrightPath Consulting LLC", "Horizon Advisory Services", "44-5566778"},
    {"Ironclad Security Systems", "Guardian Protective Services", "55-6677889"},
    {"Nova Data Systems Inc.", "Stellar Analytics LLC", "66-7788990"}
  ]

  # --- 3 formatting-only: same entity, cosmetic difference (abbreviation, punctuation, suffix) ---
  @formatting [
    {"Acme Corp", "Acme Corporation", "77-8899001"},
    {"J&K Supplies", "J and K Supplies, LLC", "88-9900112"},
    {"Global Tech Solutions", "Global Technology Solutions, Inc.", "99-0011223"}
  ]

  # --- 2 missing/malformed: unreadable or absent Tax ID / name ---
  @malformed [
    {"Driftwood Trading Co.", "Driftwood Trading Co.", "[illegible]"},
    {"Meridian Analytics Group", "", "N/A"}
  ]

  @spec all() :: [Fixture.t()]
  def all do
    clean() ++ mismatch() ++ formatting() ++ malformed()
  end

  defp clean do
    @clean
    |> Enum.with_index(1)
    |> Enum.map(fn {{name, tax_id, terms, liability}, i} ->
      %Fixture{
        id: "clean-#{pad(i)}",
        bucket: "clean",
        contract_text: contract_text(name, terms, liability),
        w9_text: w9_text(name, tax_id),
        expected_entity_match: true,
        expected_decision: "approved"
      }
    end)
  end

  defp mismatch do
    build_pairs(@mismatch, "mismatch", expected_entity_match: false, decision: "needs_review")
  end

  defp formatting do
    build_pairs(@formatting, "formatting", expected_entity_match: true, decision: "approved")
  end

  defp malformed do
    build_pairs(@malformed, "malformed", expected_entity_match: nil, decision: "needs_review")
  end

  defp build_pairs(rows, bucket, opts) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {{contract_name, w9_name, tax_id}, i} ->
      %Fixture{
        id: "#{bucket}-#{pad(i)}",
        bucket: bucket,
        contract_text: contract_text(contract_name, "Net 30", "Standard indemnification clause."),
        w9_text: w9_text(w9_name, tax_id),
        expected_entity_match: opts[:expected_entity_match],
        expected_decision: opts[:decision]
      }
    end)
  end

  defp pad(i), do: String.pad_leading(Integer.to_string(i), 2, "0")

  defp contract_text(company_name, payment_terms, liability_clauses) do
    """
    VENDOR SERVICES AGREEMENT

    This agreement is entered into between Buyer and #{company_name} ("Vendor").

    Payment Terms: #{payment_terms}

    Liability: #{liability_clauses}
    """
  end

  defp w9_text(company_name, tax_id) do
    """
    FORM W-9 -- Request for Taxpayer Identification Number

    1. Name of entity: #{company_name}
    2. Taxpayer Identification Number (EIN): #{tax_id}
    """
  end
end
