from pydantic import BaseModel, Field


class ContractExtraction(BaseModel):
    """Agent 1's extraction from the contract only. Payment terms and
    liability clauses only ever appear in the contract, not the W-9.
    """

    company_name: str = Field(description="Vendor's legal company name as it appears on the contract")
    payment_terms: str = Field(description="Payment terms as stated in the contract")
    liability_clauses: str = Field(
        description="Liability/indemnification clauses as stated in the contract"
    )


class W9Extraction(BaseModel):
    """Agent 1's extraction from the W-9 only. Kept separate from the
    contract extraction so Agent 2 can cross-check entities between the
    two documents (the headline name-mismatch HITL scenario).
    """

    company_name: str = Field(description="Vendor's legal company name as it appears on the W-9")
    tax_id: str = Field(
        description="Vendor's Tax ID / EIN, verbatim as it appears on the W-9"
    )


class EntityMatchResult(BaseModel):
    """Agent 2's judgment on whether the contract and W-9 company names refer
    to the same legal entity. An LLM call, not string equality — a formatting
    difference ("Acme Corp" vs "Acme Corporation") must not be flagged as a
    mismatch (see CONTEXT.md's false-positive eval bucket).
    """

    match: bool = Field(
        description="Whether the contract and W-9 company names refer to the same legal entity"
    )
    explanation: str = Field(description="Brief explanation grounded in the two names compared")


class ValidationResult(BaseModel):
    """Agent 2's combined validation output: entity match + the two MCP tool
    calls. `approved` is the decision branch input.
    """

    entity_match: EntityMatchResult
    tax_id_valid: bool
    sanctions_flagged: bool
    sanctions_reason: str | None = None

    @property
    def approved(self) -> bool:
        return self.entity_match.match and self.tax_id_valid and not self.sanctions_flagged
