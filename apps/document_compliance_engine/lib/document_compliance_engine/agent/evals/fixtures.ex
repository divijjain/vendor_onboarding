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
      image_paths: nil,
      # Opt-in, per fixture: the exact values extraction should produce,
      # for cases where the right answer is the thing under test and the
      # pipeline's reaction to it isn't enough to tell. See
      # `Deterministic.expected_fields_ok?/2`.
      expected_fields: nil
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            bucket: String.t(),
            document_type_slug: String.t(),
            documents: %{String.t() => String.t()} | nil,
            image_paths: %{String.t() => Path.t()} | nil,
            expected_decision: String.t(),
            expected_entity_match: boolean() | nil,
            expected_fields: %{String.t() => %{atom() => String.t()}} | nil
          }
  end

  @spec all() :: [Fixture.t()]
  def all do
    vendor_contract_w9() ++
      invoice() ++
      scanned() ++
      bank_details() ++
      purchase_order() ++
      receipt() ++
      payroll_statement() ++
      certificate_of_insurance() ++
      w8ben() ++
      business_registration()
  end

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

  # --- bank_details: the two rule types that do real algorithmic work ----------
  #
  # This type was seeded with the rest of the library and had no fixtures —
  # a breadth claim with no accuracy evidence behind it. These exist for the
  # part of it that isn't shared with any other type: a `format` rule running
  # the ISO 13616 mod-97 checksum, and a `regex` rule on the BIC. The invalid
  # bucket is the one that matters, because a right-shaped IBAN with a wrong
  # check digit is exactly what a naive length/pattern check waves through.

  # Standard published test IBANs — real, checksum-valid values, not invented
  # strings that happen to look plausible.
  @valid_bank_accounts [
    {"Harborview Logistics Ltd", "Barclays Bank", "GB82WEST12345698765432", "BARCGB22"},
    {"Alpine Instruments GmbH", "Deutsche Bank", "DE89370400440532013000", "DEUTDEFF"}
  ]

  # Same IBANs with a single altered check digit: right country, right length,
  # right shape, wrong number. Only the mod-97 checksum tells them apart.
  @invalid_bank_accounts [
    {"Cedar Point Supplies", "Barclays Bank", "GB82WEST12345698765433", "BARCGB22"},
    {"Northgate Machining", "Deutsche Bank", "DE89370400440532013001", "DEUTDEFF"}
  ]

  @spec bank_details() :: [Fixture.t()]
  def bank_details do
    clean =
      @valid_bank_accounts
      |> Enum.with_index(1)
      |> Enum.map(fn {{holder, bank, iban, bic}, i} ->
        %Fixture{
          id: "bank-clean-#{pad(i)}",
          bucket: "bank_details_clean",
          document_type_slug: "bank_details",
          documents: %{"bank_details" => bank_details_text(holder, bank, iban, bic)},
          expected_decision: "approved"
        }
      end)

    invalid =
      @invalid_bank_accounts
      |> Enum.with_index(1)
      |> Enum.map(fn {{holder, bank, iban, bic}, i} ->
        %Fixture{
          id: "bank-bad-iban-#{pad(i)}",
          bucket: "bank_details_invalid_iban",
          document_type_slug: "bank_details",
          documents: %{"bank_details" => bank_details_text(holder, bank, iban, bic)},
          expected_decision: "needs_review"
        }
      end)

    # The same watchlisted name the invoice sanctions bucket uses, arriving on
    # a different document type — payment details for a sanctioned entity is
    # the most consequential version of that hit.
    sanctioned = [
      %Fixture{
        id: "bank-sanctions-01",
        bucket: "bank_details_sanctions_hit",
        document_type_slug: "bank_details",
        documents: %{
          "bank_details" =>
            bank_details_text(
              "Rogue Exports LLC",
              "Barclays Bank",
              "GB82WEST12345698765432",
              "BARCGB22"
            )
        },
        expected_decision: "needs_review"
      }
    ]

    clean ++ invalid ++ sanctioned
  end

  defp bank_details_text(holder, bank, iban, bic) do
    """
    VENDOR BANK DETAILS

    Please route all payments to the account below.

    Account holder: #{holder}
    Bank details: #{bank}
    IBAN: #{iban}
    BIC/SWIFT: #{bic}
    """
  end

  # --- purchase_order: the bucket that tests whether descriptions do anything -
  #
  # `order_date` and `delivery_date` are both `date`-typed and both present on
  # every one of these documents; nothing about the field *names* says which
  # is which when the document labels them "Raised" and "Required By". The
  # only thing that disambiguates them is the semantic description on each
  # field. That claim was made when descriptions were added and never
  # measured — the `dates` bucket below is the measurement.

  @purchase_orders [
    {"Northwind Buyers Inc.", "Acme Corp", "PO-4501", "2026-09-01", "2026-09-30", "12,400.00"},
    {"Lakeside Manufacturing", "Summit Peak Freight LLC", "PO-4502", "2026-08-15", "2026-09-15",
     "3,150.00"}
  ]

  @spec purchase_order() :: [Fixture.t()]
  def purchase_order do
    clean =
      @purchase_orders
      |> Enum.with_index(1)
      |> Enum.map(fn {{buyer, supplier, po, ordered, delivery, total}, i} ->
        %Fixture{
          id: "po-clean-#{pad(i)}",
          bucket: "purchase_order_clean",
          document_type_slug: "purchase_order",
          documents: %{
            "purchase_order" => purchase_order_text(buyer, supplier, po, ordered, delivery, total)
          },
          expected_decision: "approved"
        }
      end)

    # Same content, but the two dates are labelled in a way that gives the
    # field names no help at all, and a third date (the print date) is added
    # as a distractor. Correct extraction here is evidence the descriptions
    # are doing work; a wrong one is caught by grounding, not by this
    # expectation, so the bucket is honest either way.
    dates =
      [
        {"Fairview Trading Co.", "Blue Ridge Logistics Inc.", "PO-4503", "2026-07-02",
         "2026-08-20", "8,900.00"}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{buyer, supplier, po, ordered, delivery, total}, i} ->
        %Fixture{
          id: "po-dates-#{pad(i)}",
          bucket: "purchase_order_dates",
          document_type_slug: "purchase_order",
          documents: %{
            "purchase_order" =>
              ambiguous_date_purchase_order_text(buyer, supplier, po, ordered, delivery, total)
          },
          # The point of this bucket: both dates are verbatim present, so a
          # swap is approved *and* fully grounded. Only naming the right
          # answer catches it.
          expected_fields: %{
            "purchase_order" => %{order_date: ordered, delivery_date: delivery}
          },
          expected_decision: "approved"
        }
      end)

    sanctioned = [
      %Fixture{
        id: "po-sanctions-01",
        bucket: "purchase_order_sanctions_hit",
        document_type_slug: "purchase_order",
        documents: %{
          "purchase_order" =>
            purchase_order_text(
              "Northwind Buyers Inc.",
              "North Star Trading Co",
              "PO-4504",
              "2026-09-01",
              "2026-10-01",
              "5,000.00"
            )
        },
        expected_decision: "needs_review"
      }
    ]

    clean ++ dates ++ sanctioned
  end

  defp purchase_order_text(buyer, supplier, po, ordered, delivery, total) do
    """
    PURCHASE ORDER

    PO Number: #{po}
    Buyer: #{buyer}
    Supplier: #{supplier}
    Ship To: #{buyer}, 14 Commerce Way

    Order Date: #{ordered}
    Delivery Date: #{delivery}

    Order Total: #{total}
    """
  end

  defp ambiguous_date_purchase_order_text(buyer, supplier, po, ordered, delivery, total) do
    """
    PURCHASE ORDER  ·  #{po}

    Buyer: #{buyer}
    Supplier: #{supplier}
    Ship To: #{buyer}, 14 Commerce Way

    Raised: #{ordered}
    Required By: #{delivery}
    Printed: 2026-07-03

    Order Total: #{total}
    """
  end

  # --- receipt ----------------------------------------------------------------

  @spec receipt() :: [Fixture.t()]
  def receipt do
    clean =
      [
        {"Harbour Street Cafe", "18.40", "2026-08-14", "VISA ending 4242"},
        {"Northgate Stationers", "126.95", "2026-08-21", "Cash"}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{merchant, total, date, method}, i} ->
        %Fixture{
          id: "receipt-clean-#{pad(i)}",
          bucket: "receipt_clean",
          document_type_slug: "receipt",
          documents: %{"receipt" => receipt_text(merchant, total, date, method)},
          expected_decision: "approved"
        }
      end)

    # A smudged thermal receipt: the total is present and legible enough to
    # copy, but is not a monetary amount. `receipt` declares that field
    # `monetary_amount`, so the declared-type check is what catches it —
    # this type configures no rule that would.
    garbled = [
      %Fixture{
        id: "receipt-malformed-01",
        bucket: "receipt_malformed",
        document_type_slug: "receipt",
        documents: %{
          "receipt" => receipt_text("Riverside Hardware", "1?.5O", "2026-08-03", "Card")
        },
        expected_decision: "needs_review"
      }
    ]

    sanctioned = [
      %Fixture{
        id: "receipt-sanctions-01",
        bucket: "receipt_sanctions_hit",
        document_type_slug: "receipt",
        documents: %{
          "receipt" => receipt_text("Rogue Exports LLC", "310.00", "2026-08-09", "Bank transfer")
        },
        expected_decision: "needs_review"
      }
    ]

    clean ++ garbled ++ sanctioned
  end

  defp receipt_text(merchant, total, date, method) do
    """
    #{String.upcase(merchant)}
    SALES RECEIPT

    Date of purchase: #{date}

    Subtotal: 15.33
    Tax: 3.07
    Total: #{total}

    Paid by: #{method}

    Thank you for your custom.
    """
  end

  # --- payroll_statement ------------------------------------------------------
  #
  # The type with no `validation_rules` at all, which makes it the clearest
  # test of the automatic checks: everything below is caught (or not) by
  # grounding, completeness and declared types alone.

  @spec payroll_statement() :: [Fixture.t()]
  def payroll_statement do
    clean =
      [
        {"Bramble & Co Ltd", "J. Okafor", "2026-08-31", "4,200.00", "3,118.44"},
        {"Kestrel Manufacturing", "P. Lindqvist", "2026-07-31", "3,750.00", "2,806.12"}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{employer, employee, period_end, gross, net}, i} ->
        %Fixture{
          id: "payroll-clean-#{pad(i)}",
          bucket: "payroll_clean",
          document_type_slug: "payroll_statement",
          documents: %{
            "payroll_statement" => payslip_text(employer, employee, period_end, gross, net)
          },
          expected_decision: "approved"
        }
      end)

    # Both figures are monetary amounts, both are verbatim present, and a
    # swap is approved and fully grounded — the same blind spot the
    # purchase-order dates fixture exists for, on a different type. Only
    # `expected_fields` can catch it.
    gross_net = [
      %Fixture{
        id: "payroll-gross-net-01",
        bucket: "payroll_gross_net",
        document_type_slug: "payroll_statement",
        documents: %{
          "payroll_statement" =>
            payslip_text("Alderway Services", "R. Mensah", "2026-08-31", "5,010.00", "3,642.75")
        },
        expected_fields: %{
          "payroll_statement" => %{gross_pay: "5,010.00", net_pay: "3,642.75"}
        },
        expected_decision: "approved"
      }
    ]

    # A smudged scan where the figures came through as characters rather
    # than numbers. The values are present and get copied verbatim, so the
    # declared-type check (`monetary_amount`) is what catches them — on a
    # type that configures no rules of its own at all.
    malformed = [
      %Fixture{
        id: "payroll-malformed-01",
        bucket: "payroll_malformed",
        document_type_slug: "payroll_statement",
        documents: %{
          "payroll_statement" =>
            payslip_text("Thornbury Group", "A. Silva", "2026-08-31", "2,9O0.OO", "2,178.O3")
        },
        expected_decision: "needs_review"
      }
    ]

    # Pinned deliberately as `approved`, and it is a **known blind spot,
    # not a desirable outcome**: exactly one field is unreadable, the model
    # honestly reports it absent, and nothing catches that. Blank values
    # belong to `extraction_completeness_checks/1`, which only fires above
    # 50% missing — one field in five never reaches it — and this type has
    # no rule that would look. Found by this corpus when the fixture above
    # was first written this way and came back approved. It stays as a
    # regression test for the behaviour that exists, so that a future change
    # to the completeness rule shows up here as a deliberate change rather
    # than a surprise. See CONTEXT.md's dated entry.
    single_missing = [
      %Fixture{
        id: "payroll-partial-01",
        bucket: "payroll_single_missing_field",
        document_type_slug: "payroll_statement",
        documents: %{
          "payroll_statement" =>
            payslip_text("Thornbury Group", "A. Silva", "--/--/----", "2,900.00", "2,178.03")
        },
        expected_decision: "approved"
      }
    ]

    clean ++ gross_net ++ malformed ++ single_missing
  end

  defp payslip_text(employer, employee, period_end, gross, net) do
    """
    #{employer}
    PAYSLIP

    Employee: #{employee}
    Pay Period ending: #{period_end}

    Earnings
      Gross Pay: #{gross}

    Deductions
      Income tax: 812.00
      Pension: 190.00

    Net Pay: #{net}
    """
  end

  # --- certificate_of_insurance -----------------------------------------------
  #
  # Dates are computed relative to the day the harness runs, not written as
  # literals. A committed fixture asserting "valid until 2027-06-01" is a
  # fixture that silently becomes a failing one in June 2027 — the one kind
  # of corpus rot a time-dependent rule guarantees if the corpus pretends
  # time doesn't move.

  @spec certificate_of_insurance() :: [Fixture.t()]
  def certificate_of_insurance do
    today = Date.utc_today()
    starts = Date.to_iso8601(Date.add(today, -30))
    expires = Date.to_iso8601(Date.add(today, 335))
    lapsed = Date.to_iso8601(Date.add(today, -14))

    clean =
      [
        {"Fenwick Contracting Ltd", "Sterling Mutual", "POL-88213", "2,000,000.00"},
        {"Ardent Facilities Group", "Northern Underwriters", "POL-90471", "5,000,000.00"}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{insured, insurer, policy, cover}, i} ->
        %Fixture{
          id: "coi-clean-#{pad(i)}",
          bucket: "coi_clean",
          document_type_slug: "certificate_of_insurance",
          documents: %{
            "certificate_of_insurance" =>
              coi_text(insured, insurer, policy, cover, starts, expires)
          },
          expected_decision: "approved"
        }
      end)

    # The finding no amount of reading the document produces: everything on
    # it is correct, well-formed and grounded, and the cover ran out a
    # fortnight ago.
    expired = [
      %Fixture{
        id: "coi-expired-01",
        bucket: "coi_expired",
        document_type_slug: "certificate_of_insurance",
        documents: %{
          "certificate_of_insurance" =>
            coi_text(
              "Meadow Lane Logistics",
              "Sterling Mutual",
              "POL-77410",
              "1,000,000.00",
              Date.to_iso8601(Date.add(today, -379)),
              lapsed
            )
        },
        expected_decision: "needs_review"
      }
    ]

    sanctioned = [
      %Fixture{
        id: "coi-sanctions-01",
        bucket: "coi_sanctions_hit",
        document_type_slug: "certificate_of_insurance",
        documents: %{
          "certificate_of_insurance" =>
            coi_text(
              "North Star Trading Co",
              "Northern Underwriters",
              "POL-31228",
              "1,500,000.00",
              starts,
              expires
            )
        },
        expected_decision: "needs_review"
      }
    ]

    clean ++ expired ++ sanctioned
  end

  defp coi_text(insured, insurer, policy, cover, starts, expires) do
    """
    CERTIFICATE OF INSURANCE

    Insurer: #{insurer}
    Insured: #{insured}
    Policy Number: #{policy}

    Coverage: General liability
    Liability limit: #{cover}

    Effective from: #{starts}
    Expires: #{expires}

    This certificate is issued as a matter of information only.
    """
  end

  # --- w8ben ------------------------------------------------------------------

  @spec w8ben() :: [Fixture.t()]
  def w8ben do
    clean =
      [
        {"Lindqvist Verkstad AB", "Sweden", "SE556677889901", "2026-08-02"},
        {"Bergmann Werkzeuge GmbH", "Germany", "DE123456789", "2026-07-19"}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{entity, country, vat, signed}, i} ->
        %Fixture{
          id: "w8ben-clean-#{pad(i)}",
          bucket: "w8ben_clean",
          document_type_slug: "w8ben",
          documents: %{"w8ben" => w8ben_text(entity, country, vat, signed)},
          expected_decision: "approved"
        }
      end)

    # Right country prefix, wrong body: `DE` VAT numbers are nine digits.
    # The `vat_id` validator knows the per-jurisdiction shape; a generic
    # "two letters then digits" check would pass this.
    invalid_vat = [
      %Fixture{
        id: "w8ben-invalid-vat-01",
        bucket: "w8ben_invalid_vat",
        document_type_slug: "w8ben",
        documents: %{
          "w8ben" => w8ben_text("Kappel Industrie GmbH", "Germany", "DE12345", "2026-08-11")
        },
        expected_decision: "needs_review"
      }
    ]

    sanctioned = [
      %Fixture{
        id: "w8ben-sanctions-01",
        bucket: "w8ben_sanctions_hit",
        document_type_slug: "w8ben",
        documents: %{
          "w8ben" => w8ben_text("Rogue Exports LLC", "Cyprus", "CY12345678X", "2026-08-05")
        },
        expected_decision: "needs_review"
      }
    ]

    clean ++ invalid_vat ++ sanctioned
  end

  defp w8ben_text(entity, country, vat, signed) do
    """
    FORM W-8BEN-E
    Certificate of Status of Beneficial Owner for United States Tax Withholding

    1. Name of organization that is the beneficial owner: #{entity}
    2. Country of residence: #{country}
    3. VAT registration number: #{vat}

    The beneficial owner claims foreign status under the applicable tax treaty.

    Signed on: #{signed}
    """
  end

  # --- business_registration --------------------------------------------------

  @spec business_registration() :: [Fixture.t()]
  def business_registration do
    clean =
      [
        {"Halewood Components Ltd", "SC418822", "Scotland", "12 Dockside Road, Glasgow G51 2QT",
         "accounts@halewood-components.co.uk", "+44 141 555 0182",
         "https://halewood-components.co.uk"},
        {"Aster Print Works Limited", "10992431", "England and Wales",
         "4 Bellmount Way, Leeds LS17 8RQ", "hello@asterprint.co.uk", "+44 113 555 0119",
         "https://asterprint.co.uk"}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{name, number, jurisdiction, address, email, phone, site}, i} ->
        %Fixture{
          id: "reg-clean-#{pad(i)}",
          bucket: "business_registration_clean",
          document_type_slug: "business_registration",
          documents: %{
            "business_registration" =>
              registration_text(name, number, jurisdiction, address, email, phone, site)
          },
          expected_decision: "approved"
        }
      end)

    # An address that is a fragment rather than an address — the
    # `postal_address` validator's only real job, and the weakest check in
    # `FormatValidators`, tested for what it actually claims rather than
    # what its name suggests.
    bad_address = [
      %Fixture{
        id: "reg-bad-address-01",
        bucket: "business_registration_bad_address",
        document_type_slug: "business_registration",
        documents: %{
          "business_registration" =>
            registration_text(
              "Cobalt Survey Services Ltd",
              "11238844",
              "England and Wales",
              "Suite 4",
              "office@cobaltsurvey.co.uk",
              "+44 20 7555 0143",
              "https://cobaltsurvey.co.uk"
            )
        },
        expected_decision: "needs_review"
      }
    ]

    clean ++ bad_address
  end

  defp registration_text(name, number, jurisdiction, address, email, phone, site) do
    """
    CERTIFICATE OF INCORPORATION
    Companies Registry — #{jurisdiction}

    This is to certify that

      #{name}

    is incorporated under the Companies Act and is in good standing.

    Registration number: #{number}
    Registered office: #{address}

    Contact email: #{email}
    Telephone: #{phone}
    Website: #{site}
    """
  end
end
