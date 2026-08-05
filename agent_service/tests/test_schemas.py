import pytest
from pydantic import ValidationError

from app.schemas import ContractExtraction, EntityMatchResult, ValidationResult, W9Extraction


def test_contract_extraction_requires_all_fields():
    with pytest.raises(ValidationError):
        ContractExtraction(company_name="Acme Corp")


def test_w9_extraction_accepts_required_fields():
    w9 = W9Extraction(company_name="Acme Corp", tax_id="12-3456789")
    assert w9.tax_id == "12-3456789"


def test_validation_result_approved_requires_match_valid_tax_id_and_no_sanctions_hit():
    approved = ValidationResult(
        entity_match=EntityMatchResult(match=True, explanation="same entity"),
        tax_id_valid=True,
        sanctions_flagged=False,
    )
    assert approved.approved is True

    mismatched = approved.model_copy(
        update={"entity_match": EntityMatchResult(match=False, explanation="different vendor")}
    )
    assert mismatched.approved is False

    invalid_tax_id = approved.model_copy(update={"tax_id_valid": False})
    assert invalid_tax_id.approved is False

    sanctioned = approved.model_copy(update={"sanctions_flagged": True})
    assert sanctioned.approved is False
