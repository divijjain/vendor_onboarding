import logging
import os

import httpx
from dotenv import load_dotenv
from fastapi import BackgroundTasks, FastAPI
from langgraph.types import Command
from pydantic import BaseModel

from app.checkpointer import get_checkpointer
from app.graph import build_graph
from app.schemas import CallbackPayload

load_dotenv()

logger = logging.getLogger(__name__)

app = FastAPI()


def callback_url() -> str:
    return os.environ.get("PHOENIX_CALLBACK_URL", "http://localhost:4000/webhooks/agent_callback")


class TriggerRequest(BaseModel):
    onboarding_id: int
    document_paths: dict[str, str]


class ResumeRequest(BaseModel):
    onboarding_id: int
    thread_id: str
    decision: str


class AcceptedResponse(BaseModel):
    accepted: bool
    onboarding_id: int


def read_document(path: str) -> str:
    # Documents are simulated vendor emails, not real binary PDFs — see
    # CONTEXT.md's "(simulated payload)" framing — so plain-text read is enough.
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


async def send_callback(payload: CallbackPayload) -> None:
    async with httpx.AsyncClient() as client:
        await client.post(
            callback_url(), json=payload.model_dump(exclude_none=True), timeout=30
        )


def thread_id_for(onboarding_id: int) -> str:
    return f"onboarding-{onboarding_id}"


def _extraction_fields(result: dict) -> dict:
    contract = result["contract_extraction"]
    w9 = result["w9_extraction"]

    return {
        "company_name": contract.company_name,
        "w9_company_name": w9.company_name,
        "tax_id": w9.tax_id,
        "payment_terms": contract.payment_terms,
        "liability_clauses": contract.liability_clauses,
    }


def _callback_payload(onboarding_id: int, result: dict) -> CallbackPayload:
    fields = _extraction_fields(result)

    if "__interrupt__" in result:
        return CallbackPayload(
            onboarding_id=onboarding_id,
            status="needs_review",
            thread_id=thread_id_for(onboarding_id),
            explanation=result["__interrupt__"][0].value["explanation"],
            **fields,
        )

    return CallbackPayload(onboarding_id=onboarding_id, status="approved", **fields)


def _failure_payload(onboarding_id: int, exc: Exception) -> CallbackPayload:
    return CallbackPayload(
        onboarding_id=onboarding_id,
        status="failed",
        explanation=f"Agent run failed: {type(exc).__name__}: {exc}",
    )


async def run_agent_run(onboarding_id: int, document_paths: dict[str, str]) -> None:
    try:
        contract_text = read_document(document_paths["contract"])
        w9_text = read_document(document_paths["w9"])

        async with get_checkpointer() as checkpointer:
            await checkpointer.setup()
            graph = build_graph(checkpointer=checkpointer)
            config = {"configurable": {"thread_id": thread_id_for(onboarding_id)}}
            result = await graph.ainvoke(
                {"contract_text": contract_text, "w9_text": w9_text}, config
            )
    except Exception as exc:
        logger.exception("agent run failed for onboarding %s", onboarding_id)
        await send_callback(_failure_payload(onboarding_id, exc))
        return

    await send_callback(_callback_payload(onboarding_id, result))


async def run_resume(onboarding_id: int, thread_id: str, decision: str) -> None:
    try:
        async with get_checkpointer() as checkpointer:
            graph = build_graph(checkpointer=checkpointer)
            config = {"configurable": {"thread_id": thread_id}}
            result = await graph.ainvoke(Command(resume=decision), config)
    except Exception as exc:
        logger.exception("resume failed for onboarding %s", onboarding_id)
        await send_callback(_failure_payload(onboarding_id, exc))
        return

    await send_callback(
        CallbackPayload(
            onboarding_id=onboarding_id,
            status=result["decision"],
            explanation=result.get("explanation"),
            **_extraction_fields(result),
        )
    )


@app.post("/trigger", status_code=202)
def trigger(request: TriggerRequest, background_tasks: BackgroundTasks) -> AcceptedResponse:
    background_tasks.add_task(
        run_agent_run, request.onboarding_id, request.document_paths
    )
    return AcceptedResponse(accepted=True, onboarding_id=request.onboarding_id)


@app.post("/resume", status_code=202)
def resume(request: ResumeRequest, background_tasks: BackgroundTasks) -> AcceptedResponse:
    background_tasks.add_task(
        run_resume, request.onboarding_id, request.thread_id, request.decision
    )
    return AcceptedResponse(accepted=True, onboarding_id=request.onboarding_id)
