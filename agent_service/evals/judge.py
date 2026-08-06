"""DeepEval GEval judge — Claude Sonnet, deliberately a different provider
than the GPT-4o-mini agents (see CONTEXT.md's anti-self-grading decision).
Requires ANTHROPIC_API_KEY to actually run; not needed to import this
module or build the harness's plumbing.
"""

from deepeval.metrics import GEval
from deepeval.test_case import SingleTurnParams


def _judge_model():
    from deepeval.models.llms.anthropic_model import AnthropicModel

    # Not yet in deepeval's static cost registry, so costs are given explicitly.
    return AnthropicModel(model="claude-sonnet-5", cost_per_input_token=0, cost_per_output_token=0)


def build_entity_match_metric(threshold: float = 0.7) -> GEval:
    """Entity-mapping correctness under formatting variation — the false-
    positive-rate check from CONTEXT.md's eval design.
    """
    return GEval(
        name="Entity Match Correctness",
        criteria=(
            "The input gives a contract company name and a W-9 company name. "
            "The actual output states whether the agent judged them to be the "
            "same legal entity. The expected output states the correct "
            "judgment. Score high only if the actual judgment (match or no "
            "match) agrees with the expected judgment — formatting "
            "differences like abbreviations or a missing legal suffix should "
            "still count as a match."
        ),
        evaluation_params=[
            SingleTurnParams.INPUT,
            SingleTurnParams.ACTUAL_OUTPUT,
            SingleTurnParams.EXPECTED_OUTPUT,
        ],
        model=_judge_model(),
        threshold=threshold,
    )


def build_groundedness_metric(threshold: float = 0.7) -> GEval:
    """Whether the agent's drafted mismatch explanation is actually grounded
    in the real discrepancy, not invented.
    """
    return GEval(
        name="Explanation Groundedness",
        criteria=(
            "The context lists the actual discrepancy findings from "
            "validation. The actual output is the agent's drafted "
            "explanation of the discrepancy. Score high only if every claim "
            "in the actual output is supported by the context, with no "
            "invented facts."
        ),
        evaluation_params=[
            SingleTurnParams.INPUT,
            SingleTurnParams.ACTUAL_OUTPUT,
            SingleTurnParams.CONTEXT,
        ],
        model=_judge_model(),
        threshold=threshold,
    )
