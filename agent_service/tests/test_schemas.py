import pytest
from pydantic import ValidationError

from app.schemas import ExtractionResult


def test_extraction_result_accepts_all_required_fields():
    result = ExtractionResult(
        company_name="Acme Corp",
        tax_id="12-3456789",
        payment_terms="Net 30",
        liability_clauses="Standard indemnification clause.",
    )

    assert result.company_name == "Acme Corp"
    assert result.tax_id == "12-3456789"


def test_extraction_result_requires_all_fields():
    with pytest.raises(ValidationError):
        ExtractionResult(company_name="Acme Corp")
