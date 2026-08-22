defmodule DocumentComplianceEngine.Agent.Evals.Fixtures do
  @moduledoc """
  Synthetic document_job fixtures, deliberately structured into buckets
  (not randomly generated) so the eval's bucket counts are auditable — see
  CONTEXT.md's evaluation design. Spans two document types, proven
  document-type-generic the same way the pipeline itself was: `all/0` is
  every fixture across both, but `vendor_contract_w9/0` and `invoice/0`
  are each independently meaningful (and independently run — see
  `Evals.Run`).

  **`vendor_contract_w9`** — 55 fixtures, grown from an original 20
  (10/5/3/2) specifically to give the two thinnest buckets — formatting
  and malformed — enough cases that a single failure doesn't swing that
  bucket's accuracy by 33-50 points; still not a rigorous benchmark-scale
  set, just past the point where the numbers were mostly noise (see
  CONTEXT.md's dated entry on the expansion).

    20 clean               -> should auto-approve
    15 genuine mismatch    -> should flag (true positives)
    12 formatting-only     -> NOT a real mismatch (tests false-positive rate)
     8 missing/malformed   -> tests graceful degradation

  **`invoice`** — 16 fixtures, sized to what the type's actual rule
  surface can meaningfully exercise (one business rule — `screen_vendor`
  — plus the two automatic checks every document type gets for free:
  `Checks.grounded_extraction_checks/3` and
  `Checks.extraction_completeness_checks/1`, see CONTEXT.md's dated entry
  on why those exist):

     6 clean               -> should auto-approve
     2 sanctions hit        -> should flag (the two names the mock
                               `sanctions_db` server actually watchlists —
                               see `SanctionsDb.Server`'s `@sanctioned_names`,
                               not invented, so a real eval run's result is
                               a genuine pass/fail against that mock, not a
                               coin flip)
     2 sanctions evasion    -> should also flag — real adversarial-testing
                               finds (an inserted word, a Cyrillic "о"
                               homoglyph), not hypothetical worst-cases.
                               Every one of these auto-approved with zero
                               human review before `SanctionsDb.Server`
                               grew fuzzy matching — see CONTEXT.md's dated
                               entry. A standing regression check for that
                               fix, not just a smoke test.
     3 malformed            -> vendor name present and grounded, but most
                               other fields genuinely absent from the
                               source — tests `extraction_completeness`
     3 wrong document type  -> not an invoice at all (résumé/cover-letter
                               shaped text) — tests the shape gate
                               (`Extraction.shape_matches?/2`) catches it
                               *before* any extraction call, zero LLM cost.
                               This bucket exists because of a real
                               incident, not a hypothetical: an uploaded
                               résumé was extracted into a fully fabricated
                               invoice before this check existed — see
                               CONTEXT.md's dated entry.

  **`scanned`** — 8 fixtures, the only bucket that exercises `PdfText`'s
  vision-transcription fallback (every other fixture above is plain text,
  fed straight to the reactor, and never touches `PdfText` at all — see
  `Evals.Run.build_documents/1`). This is a smoke test, not a benchmark:
  eight synthetic images is nowhere near enough to make a real accuracy
  claim about vision transcription in general, only enough to prove the
  fallback path is wired correctly end-to-end against real image bytes
  instead of one hand-picked demo. See CONTEXT.md's dated entry.

     2 clean    -> rendered invoice text, mild rotate+blur, fully
                   legible -> should auto-approve
     1 sanctions-hit -> same, vendor name is one of `SanctionsDb.Server`'s
                   real watchlisted names -> should flag
     1 malformed -> vendor name rendered clearly, remaining fields
                   rendered then heavily blurred into genuine illegibility
                   -> tests that the vision prompt's "[illegible], never
                   guess" discipline survives into extraction_completeness
                   the same way a malformed text fixture does
     2 layout-diverse -> deliberately NOT the same template as the four
                   above (which only ever vary rotation/blur on one fixed
                   field order/wording) — a columnar/table invoice with a
                   header text box, and a letterhead invoice with no
                   "Vendor:" label at all and different field wording
                   ("Balance Due" not "Amount Due", "Client" not "Bill
                   To") -> both should still auto-approve. Added because
                   rotation/blur alone tests image-quality robustness, not
                   layout robustness, which is closer to what actually
                   varies between real vendors' invoices — see CONTEXT.md's
                   dated entry, including a real transcription-completeness
                   miss this pair surfaced that the other four never would
                   have.
     2 photo-realistic -> still a step short of a real phone photo (no
                   real camera, real paper, or real hand tremor), but a
                   harder synthetic proxy than plain rotate+blur: one uses
                   an actual geometric perspective distortion (`-distort
                   Perspective`, not just `-rotate`) plus grain and heavy
                   JPEG re-compression; the other simulates uneven ambient
                   lighting/glare via a composited radial gradient, also
                   JPEG. Both fully legible, both should auto-approve —
                   this bucket is about capture-artifact robustness, not
                   legibility (that's `malformed`) or layout (that's
                   `layout-diverse`). Also the first *real* end-to-end
                   verification of `PdfText`'s JPEG-magic-byte path against
                   actual image content — every earlier vision fixture was
                   a PNG. See CONTEXT.md's dated entry.
  """

  defmodule Fixture do
    @moduledoc false
    @enforce_keys [:id, :bucket, :document_type_slug, :expected_decision]
    defstruct [
      :id,
      :bucket,
      :document_type_slug,
      :expected_decision,
      # nil where the check doesn't meaningfully apply (malformed w9 docs,
      # or any invoice fixture — invoice has no entity-match concept).
      :expected_entity_match,
      # Exactly one of `documents`/`image_paths` is set. Plain-text
      # fixtures set `documents` and go straight to the reactor.
      # Image-backed fixtures (the `scanned` bucket) set `image_paths`
      # instead — real PNG bytes on disk that `Evals.Run.build_documents/1`
      # reads and runs through `PdfText.extract/1` first, the same as
      # production's `Agent.Run.read_documents/2` does, so the eval
      # actually exercises the vision-transcription path rather than
      # assuming it works from a hand-picked demo.
      documents: nil,
      image_paths: nil
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            bucket: String.t(),
            document_type_slug: String.t(),
            documents: %{String.t() => String.t()} | nil,
            image_paths: %{String.t() => Path.t()} | nil,
            expected_decision: String.t(),
            expected_entity_match: boolean() | nil
          }
  end

  @spec all() :: [Fixture.t()]
  def all, do: vendor_contract_w9() ++ invoice() ++ scanned()

  @spec vendor_contract_w9() :: [Fixture.t()]
  def vendor_contract_w9 do
    w9_clean() ++ w9_mismatch() ++ w9_formatting() ++ w9_malformed()
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

  defp w9_clean do
    @clean
    |> Enum.with_index(1)
    |> Enum.map(fn {{name, tax_id, terms, liability}, i} ->
      %Fixture{
        id: "clean-#{pad(i)}",
        bucket: "clean",
        document_type_slug: "vendor_contract_w9",
        documents: %{
          "contract" => contract_text(name, terms, liability),
          "w9" => w9_text(name, tax_id)
        },
        expected_entity_match: true,
        expected_decision: "approved"
      }
    end)
  end

  defp w9_mismatch do
    w9_pairs(@mismatch, "mismatch", expected_entity_match: false, decision: "needs_review")
  end

  defp w9_formatting do
    w9_pairs(@formatting, "formatting", expected_entity_match: true, decision: "approved")
  end

  defp w9_malformed do
    w9_pairs(@malformed, "malformed", expected_entity_match: nil, decision: "needs_review")
  end

  defp w9_pairs(rows, bucket, opts) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {{contract_name, w9_name, tax_id}, i} ->
      %Fixture{
        id: "#{bucket}-#{pad(i)}",
        bucket: bucket,
        document_type_slug: "vendor_contract_w9",
        documents: %{
          "contract" =>
            contract_text(contract_name, "Net 30", "Standard indemnification clause."),
          "w9" => w9_text(w9_name, tax_id)
        },
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

  @spec invoice() :: [Fixture.t()]
  def invoice do
    invoice_clean() ++
      invoice_sanctions_hit() ++
      invoice_sanctions_evasion() ++ invoice_malformed() ++ invoice_wrong_type()
  end

  @invoice_clean [
    {"Acme Corp", "INV-1001", "1,000.00", "2026-09-01"},
    {"Blue Ridge Logistics Inc.", "INV-1002", "2,450.50", "2026-09-15"},
    {"Summit Peak Freight LLC", "INV-1003", "875.00", "2026-10-01"},
    {"Golden Gate Supplies Co.", "INV-1004", "12,300.00", "2026-08-30"},
    {"Northwind Traders Ltd.", "INV-1005", "540.25", "2026-09-20"},
    {"Pioneer Manufacturing Inc.", "INV-1006", "3,200.00", "2026-10-05"}
  ]

  # The exact two names `SanctionsDb.Server`'s mock watchlist flags on a
  # certain (similarity 1.0, post-normalization) match — not invented
  # values that would pass or fail by coincidence.
  @invoice_sanctioned ["Rogue Exports LLC", "North Star Trading Co"]

  # Real evasion attempts against "Rogue Exports LLC" found via
  # adversarial testing, not invented worst-cases — an extra word and a
  # Cyrillic "о" homoglyph substitution, the two attempts that scored
  # closest to `SanctionsDb.Server`'s fuzzy-match threshold rather than
  # the easiest ones to catch. Before the fuzzy-match fix, every one of
  # these sailed through the old exact-match-only screen to full
  # auto-approval with zero human review. See CONTEXT.md's dated entry.
  @invoice_sanctions_evasion ["Rogue Global Exports LLC", "Rоge Exports LLC"]

  defp invoice_clean do
    @invoice_clean
    |> Enum.with_index(1)
    |> Enum.map(fn {{vendor, invoice_number, amount, due_date}, i} ->
      %Fixture{
        id: "invoice-clean-#{pad(i)}",
        bucket: "invoice_clean",
        document_type_slug: "invoice",
        documents: %{"invoice" => invoice_text(vendor, invoice_number, amount, due_date)},
        expected_decision: "approved"
      }
    end)
  end

  defp invoice_sanctions_hit do
    @invoice_sanctioned
    |> Enum.with_index(1)
    |> Enum.map(fn {vendor, i} ->
      %Fixture{
        id: "invoice-sanctions-#{pad(i)}",
        bucket: "invoice_sanctions_hit",
        document_type_slug: "invoice",
        documents: %{
          "invoice" => invoice_text(vendor, "INV-20#{i}0", "999.99", "2026-09-30")
        },
        expected_decision: "needs_review"
      }
    end)
  end

  defp invoice_sanctions_evasion do
    @invoice_sanctions_evasion
    |> Enum.with_index(1)
    |> Enum.map(fn {vendor, i} ->
      %Fixture{
        id: "invoice-sanctions-evasion-#{pad(i)}",
        bucket: "invoice_sanctions_evasion",
        document_type_slug: "invoice",
        documents: %{
          "invoice" => invoice_text(vendor, "INV-21#{i}0", "750.00", "2026-10-10")
        },
        expected_decision: "needs_review"
      }
    end)
  end

  @invoice_malformed ["Fairview Trading Co.", "Redstone Analytics Inc.", "Coldwater Freight LLC"]

  defp invoice_malformed do
    @invoice_malformed
    |> Enum.with_index(1)
    |> Enum.map(fn {vendor, i} ->
      %Fixture{
        id: "invoice-malformed-#{pad(i)}",
        bucket: "invoice_malformed",
        document_type_slug: "invoice",
        documents: %{
          "invoice" => """
          INVOICE

          Vendor: #{vendor}

          (Remaining invoice details are illegible in the scanned copy.)
          """
        },
        expected_decision: "needs_review"
      }
    end)
  end

  # Real, unrelated document text (a cover letter, a résumé excerpt, an
  # email) — deliberately not invoice-shaped at all, mirroring the actual
  # incident (see moduledoc). None of these mention "invoice", "bill to",
  # or "amount due" more than once, so all three sit well under
  # `invoice`'s seeded `shape_signals` threshold of 2.
  @invoice_wrong_type [
    """
    Dear Hiring Manager,

    I am writing to express my enthusiasm for the Software Engineer
    position. As a developer who values discipline, accountability, and
    continuous improvement, I believe I would be a strong addition to
    your team.

    Sincerely,
    A Candidate
    """,
    """
    Senior Software Engineer | Example Corp, Remote

    - Developed a fintech payment application driving a total daily
      volume of $50M - $100M integrated across the company's ecosystem.
    - Led cross-functional engineering teams to deliver full-stack
      products and high-volume financial applications.
    """,
    """
    Hi team,

    Quick update on this week's sprint: we shipped the new dashboard
    and fixed the flaky CI job. Vendor onboarding for the analytics
    integration is still pending legal review.

    Thanks,
    Project Lead
    """
  ]

  defp invoice_wrong_type do
    @invoice_wrong_type
    |> Enum.with_index(1)
    |> Enum.map(fn {text, i} ->
      %Fixture{
        id: "invoice-wrong-type-#{pad(i)}",
        bucket: "invoice_wrong_type",
        document_type_slug: "invoice",
        documents: %{"invoice" => text},
        expected_decision: "needs_review"
      }
    end)
  end

  defp invoice_text(vendor, invoice_number, amount, due_date) do
    """
    INVOICE

    Bill To: Buyer Inc.
    Vendor: #{vendor}
    Invoice Number: #{invoice_number}
    Amount Due: #{amount}
    Due Date: #{due_date}
    """
  end

  @scanned_dir Application.app_dir(:document_compliance_engine, "priv/eval_fixtures/scanned")

  @spec scanned() :: [Fixture.t()]
  def scanned do
    [
      %Fixture{
        id: "scanned-clean-01",
        bucket: "scanned_clean",
        document_type_slug: "invoice",
        image_paths: %{"invoice" => scanned_path("clean_01.png")},
        expected_decision: "approved"
      },
      %Fixture{
        id: "scanned-clean-02",
        bucket: "scanned_clean",
        document_type_slug: "invoice",
        image_paths: %{"invoice" => scanned_path("clean_02.png")},
        expected_decision: "approved"
      },
      # "Rogue Exports LLC" — a real name from `SanctionsDb.Server`'s mock
      # watchlist (see `@invoice_sanctioned` above), rendered into an image
      # rather than typed as text.
      %Fixture{
        id: "scanned-sanctions-01",
        bucket: "scanned_sanctions_hit",
        document_type_slug: "invoice",
        image_paths: %{"invoice" => scanned_path("sanctions_01.png")},
        expected_decision: "needs_review"
      },
      %Fixture{
        id: "scanned-malformed-01",
        bucket: "scanned_malformed",
        document_type_slug: "invoice",
        image_paths: %{"invoice" => scanned_path("malformed_01.png")},
        expected_decision: "needs_review"
      },
      # Columnar/table layout: line-item table, invoice #/date in a
      # separate header text box instead of inline with the rest of the
      # fields, "Total Due" instead of "Amount Due". A real run of this
      # fixture found the vision transcription drops that header box
      # entirely — see CONTEXT.md's dated entry — so this fixture is also
      # a standing regression check for that, not just a layout-diversity
      # smoke test.
      %Fixture{
        id: "scanned-layout-table-01",
        bucket: "scanned_layout_diverse",
        document_type_slug: "invoice",
        image_paths: %{"invoice" => scanned_path("layout_table_01.png")},
        expected_decision: "approved"
      },
      # Letterhead layout: vendor name is the page heading with no
      # "Vendor:" label at all, plus different field wording throughout
      # ("Client" not "Bill To", "Balance Due" not "Amount Due", due date
      # phrased as "Please remit by ..."). Tests whether extraction
      # generalizes past the exact wording every other invoice fixture
      # uses, not just whether it's legible.
      %Fixture{
        id: "scanned-layout-alt-01",
        bucket: "scanned_layout_diverse",
        document_type_slug: "invoice",
        image_paths: %{"invoice" => scanned_path("layout_alt_01.png")},
        expected_decision: "approved"
      },
      # Real perspective distortion (not just -rotate) plus grain and
      # heavy JPEG re-compression — closer to a handheld photo than a flat
      # scan. Also the first fixture that's actually a JPEG on disk, so
      # this is real end-to-end coverage of PdfText's JPEG-magic-byte
      # routing, not just PNG.
      %Fixture{
        id: "scanned-photo-skew-01",
        bucket: "scanned_photo_realistic",
        document_type_slug: "invoice",
        image_paths: %{"invoice" => scanned_path("photo_skew_01.jpg")},
        expected_decision: "approved"
      },
      # Uneven ambient lighting / glare, simulated via a composited radial
      # gradient, also re-saved as JPEG. Content is fully legible — this
      # bucket is about capture-artifact robustness, not illegibility
      # (that's `scanned_malformed`).
      %Fixture{
        id: "scanned-photo-glare-01",
        bucket: "scanned_photo_realistic",
        document_type_slug: "invoice",
        image_paths: %{"invoice" => scanned_path("photo_glare_01.jpg")},
        expected_decision: "approved"
      }
    ]
  end

  defp scanned_path(filename), do: Path.join(@scanned_dir, filename)
end
