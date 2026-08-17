defmodule DocumentComplianceEngine.Agent.Evals.Fixtures do
  @moduledoc """
  55 synthetic vendor-document_job document pairs, deliberately structured
  into four buckets (not randomly generated) so the eval's bucket counts
  are auditable — see CONTEXT.md's evaluation design. Grown from an
  original 20 (10/5/3/2) specifically to give the two thinnest buckets —
  formatting and malformed — enough cases that a single failure doesn't
  swing that bucket's accuracy by 33-50 points; still not a rigorous
  benchmark-scale set, just past the point where the numbers were mostly
  noise (see CONTEXT.md's dated entry on the expansion).

    20 clean               -> should auto-approve
    15 genuine mismatch    -> should flag (true positives)
    12 formatting-only     -> NOT a real mismatch (tests false-positive rate)
     8 missing/malformed   -> tests graceful degradation
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

  # --- 20 clean: contract and W-9 name match exactly, EIN well-formed ---
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
    {"Harborview Industries Inc.", "11-2233445", "Net 45", "Standard indemnification clause."},
    {"Meridian Business Systems Inc.", "13-5790246", "Net 30",
     "Standard indemnification clause."},
    {"Coastal Ridge Enterprises LLC", "24-6801357", "Net 60",
     "Mutual indemnification for third-party claims."},
    {"Vantage Point Consulting Co.", "35-7912468", "Net 45",
     "Limited to fees paid in prior 12 months."},
    {"Timberline Equipment Corp.", "46-8023579", "Net 30", "Liability capped at contract value."},
    {"Crestwood Data Services LLC", "57-9134680", "Net 15", "Standard indemnification clause."},
    {"Alpine Ridge Logistics Inc.", "68-0245791", "Net 45",
     "Mutual indemnification for third-party claims."},
    {"Brightwater Solutions Group", "79-1356802", "Net 30", "Standard indemnification clause."},
    {"Frontier Supply Chain LLC", "80-2467913", "Net 60",
     "Limited to fees paid in prior 12 months."},
    {"Copperfield Industries Inc.", "91-3578024", "Net 30",
     "Liability capped at contract value."},
    {"Lakeside Manufacturing Co.", "12-4689135", "Net 45", "Standard indemnification clause."}
  ]

  # --- 15 genuine mismatch: contract vendor name is a different legal entity than the W-9 ---
  @mismatch [
    {"Zenith Marketing Partners", "Apex Creative Group", "22-3344556"},
    {"TransGlobal Shipping Co.", "Coastal Freight Solutions", "33-4455667"},
    {"BrightPath Consulting LLC", "Horizon Advisory Services", "44-5566778"},
    {"Ironclad Security Systems", "Guardian Protective Services", "55-6677889"},
    {"Nova Data Systems Inc.", "Stellar Analytics LLC", "66-7788990"},
    {"Redstone Financial Group", "Bluepeak Capital Partners", "14-2233440"},
    {"Summit Legal Advisors", "Crestline Law Associates", "25-3344551"},
    {"Pacific Rim Trading Co.", "Atlantic Coast Imports LLC", "36-4455662"},
    {"Quantum Engineering Corp.", "Vertex Design Studio", "47-5566773"},
    {"Meadowbrook Staffing Solutions", "Oakridge Recruiting Group", "58-6677884"},
    {"Silverstone Construction Inc.", "Ironhide Builders LLC", "69-7788995"},
    {"Brightline Media Group", "Clearview Productions", "70-8899106"},
    {"Northgate Pharmaceuticals", "Southbend Biotech LLC", "81-9900217"},
    {"Cascade Environmental Services", "Ridgeline Waste Management", "92-0011328"},
    {"Vantage Health Partners", "Wellstar Medical Group", "13-1122439"}
  ]

  # --- 12 formatting-only: same entity, cosmetic difference (abbreviation, punctuation, suffix) ---
  @formatting [
    {"Acme Corp", "Acme Corporation", "77-8899001"},
    {"J&K Supplies", "J and K Supplies, LLC", "88-9900112"},
    {"Global Tech Solutions", "Global Technology Solutions, Inc.", "99-0011223"},
    {"Smith & Sons Hardware", "Smith and Sons Hardware, LLC", "14-3344551"},
    {"Meadowview Farms & Co.", "Meadowview Farms and Company", "25-4455662"},
    {"Redbird-Hawke Logistics", "Redbird Hawke Logistics, Inc.", "36-5566773"},
    {"The Wilson Group", "Wilson Group LLC", "47-6677884"},
    {"Keystone Realty Partners", "Keystone Realty Partners, LLC", "58-7788995"},
    {"Premier Auto Parts Corp", "Premier Auto Parts Corporation", "69-8899106"},
    {"O'Brien & Sons Plumbing", "O'Brien and Sons Plumbing LLC", "70-9900217"},
    {"Delta Freight Svc. Inc.", "Delta Freight Service, Incorporated", "81-0011328"},
    {"GREENFIELD ENERGY PARTNERS", "Greenfield Energy Partners, LLC", "92-1122439"}
  ]

  # --- 8 missing/malformed: unreadable, absent, or wrong-format Tax ID / name ---
  @malformed [
    {"Driftwood Trading Co.", "Driftwood Trading Co.", "[illegible]"},
    {"Meridian Analytics Group", "", "N/A"},
    {"Hilltop Grocers LLC", "Hilltop Grocers LLC", "123456789"},
    {"[not stated]", "Coral Bay Supplies Inc.", "45-6789012"},
    {"Sunrise Foods Co.", "Sunrise Foods Co.", "not provided"},
    {"Blackwood Timber LLC", "Blackwood Timber LLC", "XX-XXXXXXX"},
    {"Riverbend Textiles", "Riverbend Textiles", "12-345"},
    {"Ashgrove Print Shop", "", ""}
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
