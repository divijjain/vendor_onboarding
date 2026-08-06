"""20 synthetic vendor-onboarding document pairs, deliberately structured
into four buckets (not randomly generated) so the eval's bucket counts are
auditable — see CONTEXT.md's evaluation design.

  10 clean               -> should auto-approve
   5 genuine mismatch    -> should flag (true positives)
   3 formatting-only     -> NOT a real mismatch (tests false-positive rate)
   2 missing/malformed   -> tests graceful degradation
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Fixture:
    id: str
    bucket: str  # "clean" | "mismatch" | "formatting" | "malformed"
    contract_text: str
    w9_text: str
    # None where the check doesn't meaningfully apply (e.g. malformed docs).
    expected_entity_match: bool | None
    expected_decision: str  # "approved" | "needs_review"


def _contract(company_name: str, payment_terms: str, liability_clauses: str) -> str:
    return (
        "VENDOR SERVICES AGREEMENT\n\n"
        f'This agreement is entered into between Buyer and {company_name} ("Vendor").\n\n'
        f"Payment Terms: {payment_terms}\n\n"
        f"Liability: {liability_clauses}\n"
    )


def _w9(company_name: str, tax_id: str) -> str:
    return (
        "FORM W-9 -- Request for Taxpayer Identification Number\n\n"
        f"1. Name of entity: {company_name}\n"
        f"2. Taxpayer Identification Number (EIN): {tax_id}\n"
    )


# --- 10 clean: contract and W-9 name match exactly, EIN well-formed ---

_CLEAN = [
    ("Acme Corp", "12-3456789", "Net 30", "Standard indemnification clause."),
    ("Blue Ridge Logistics Inc.", "23-4567891", "Net 45", "Limited to fees paid in prior 12 months."),
    ("Summit Peak Freight LLC", "34-5678912", "Net 30", "Mutual indemnification for third-party claims."),
    ("Golden Gate Supplies Co.", "45-6789123", "Net 60", "Standard indemnification clause."),
    ("Northwind Traders Ltd.", "56-7891234", "Net 30", "Liability capped at contract value."),
    ("Pioneer Manufacturing Inc.", "67-8912345", "Net 45", "Standard indemnification clause."),
    ("Cascade Software Solutions LLC", "78-9123456", "Net 15", "Mutual indemnification for third-party claims."),
    ("Redwood Consulting Group", "89-1234567", "Net 30", "Limited to fees paid in prior 12 months."),
    ("Silverline Logistics Corp.", "90-2345678", "Net 30", "Liability capped at contract value."),
    ("Harborview Industries Inc.", "11-2233445", "Net 45", "Standard indemnification clause."),
]

# --- 5 genuine mismatch: contract vendor name is a different legal entity than the W-9 ---

_MISMATCH = [
    ("Zenith Marketing Partners", "Apex Creative Group", "22-3344556"),
    ("TransGlobal Shipping Co.", "Coastal Freight Solutions", "33-4455667"),
    ("BrightPath Consulting LLC", "Horizon Advisory Services", "44-5566778"),
    ("Ironclad Security Systems", "Guardian Protective Services", "55-6677889"),
    ("Nova Data Systems Inc.", "Stellar Analytics LLC", "66-7788990"),
]

# --- 3 formatting-only: same entity, cosmetic difference (abbreviation, punctuation, suffix) ---

_FORMATTING = [
    ("Acme Corp", "Acme Corporation", "77-8899001"),
    ("J&K Supplies", "J and K Supplies, LLC", "88-9900112"),
    ("Global Tech Solutions", "Global Technology Solutions, Inc.", "99-0011223"),
]

# --- 2 missing/malformed: unreadable or absent Tax ID / name ---

_MALFORMED = [
    ("Driftwood Trading Co.", "Driftwood Trading Co.", "[illegible]"),
    ("Meridian Analytics Group", "", "N/A"),
]


def _clean_fixtures() -> list[Fixture]:
    fixtures = []
    for i, (name, tax_id, terms, liability) in enumerate(_CLEAN, start=1):
        fixtures.append(
            Fixture(
                id=f"clean-{i:02d}",
                bucket="clean",
                contract_text=_contract(name, terms, liability),
                w9_text=_w9(name, tax_id),
                expected_entity_match=True,
                expected_decision="approved",
            )
        )
    return fixtures


def _mismatch_fixtures() -> list[Fixture]:
    fixtures = []
    for i, (contract_name, w9_name, tax_id) in enumerate(_MISMATCH, start=1):
        fixtures.append(
            Fixture(
                id=f"mismatch-{i:02d}",
                bucket="mismatch",
                contract_text=_contract(contract_name, "Net 30", "Standard indemnification clause."),
                w9_text=_w9(w9_name, tax_id),
                expected_entity_match=False,
                expected_decision="needs_review",
            )
        )
    return fixtures


def _formatting_fixtures() -> list[Fixture]:
    fixtures = []
    for i, (contract_name, w9_name, tax_id) in enumerate(_FORMATTING, start=1):
        fixtures.append(
            Fixture(
                id=f"formatting-{i:02d}",
                bucket="formatting",
                contract_text=_contract(contract_name, "Net 30", "Standard indemnification clause."),
                w9_text=_w9(w9_name, tax_id),
                expected_entity_match=True,
                expected_decision="approved",
            )
        )
    return fixtures


def _malformed_fixtures() -> list[Fixture]:
    fixtures = []
    for i, (contract_name, w9_name, tax_id) in enumerate(_MALFORMED, start=1):
        fixtures.append(
            Fixture(
                id=f"malformed-{i:02d}",
                bucket="malformed",
                contract_text=_contract(contract_name, "Net 30", "Standard indemnification clause."),
                w9_text=_w9(w9_name, tax_id),
                expected_entity_match=None,
                expected_decision="needs_review",
            )
        )
    return fixtures


FIXTURES: list[Fixture] = [
    *_clean_fixtures(),
    *_mismatch_fixtures(),
    *_formatting_fixtures(),
    *_malformed_fixtures(),
]

assert len(FIXTURES) == 20
assert sum(f.bucket == "clean" for f in FIXTURES) == 10
assert sum(f.bucket == "mismatch" for f in FIXTURES) == 5
assert sum(f.bucket == "formatting" for f in FIXTURES) == 3
assert sum(f.bucket == "malformed" for f in FIXTURES) == 2
