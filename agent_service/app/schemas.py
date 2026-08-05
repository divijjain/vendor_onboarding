from pydantic import BaseModel, Field


class ExtractionResult(BaseModel):
    """Agent 1's output. Company name / tax ID are the fields validation (Agent 2)
    cross-checks against the mock Tax API and Sanctions DB; payment terms and
    liability clauses stay free text per CONTEXT.md's schema decision.
    """

    company_name: str = Field(description="Vendor's legal company name")
    tax_id: str = Field(
        description="Vendor's Tax ID / EIN, verbatim as it appears in the source documents"
    )
    payment_terms: str = Field(description="Payment terms as stated in the contract")
    liability_clauses: str = Field(
        description="Liability/indemnification clauses as stated in the contract"
    )
