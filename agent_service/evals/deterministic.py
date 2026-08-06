"""Deterministic (no-LLM) checks — pure functions, no DB, no side effects.
This is what actually produces the hallucination-rate number; see
CONTEXT.md's two-tier eval design. Pydantic schema validation is the
other deterministic check, but it's enforced by `with_structured_output`
itself (extraction either returns a valid model or raises) rather than a
separate function here — the harness catches the raise per fixture.
"""


def tax_id_verbatim(extracted_tax_id: str, source_text: str) -> bool:
    """Whether the extracted Tax ID appears verbatim in the source W-9 text.
    False means the agent hallucinated a Tax ID it didn't actually read.
    """
    tax_id = extracted_tax_id.strip()
    return tax_id != "" and tax_id in source_text
