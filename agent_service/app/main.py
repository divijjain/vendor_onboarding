import os

import httpx
from dotenv import load_dotenv
from fastapi import BackgroundTasks, FastAPI
from langgraph.types import Command
from pydantic import BaseModel

from app.checkpointer import get_checkpointer
from app.graph import build_graph

load_dotenv()

app = FastAPI()

PHOENIX_CALLBACK_URL = os.environ.get(
    "PHOENIX_CALLBACK_URL", "http://localhost:4000/webhooks/agent_callback"
)


class TriggerRequest(BaseModel):
    onboarding_id: int
    document_paths: dict[str, str]


class ResumeRequest(BaseModel):
    onboarding_id: int
    decision: str


def read_document(path: str) -> str:
    # Documents are simulated vendor emails, not real binary PDFs — see
    # CONTEXT.md's "(simulated payload)" framing — so plain-text read is enough.
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def send_callback(payload: dict) -> None:
    httpx.post(PHOENIX_CALLBACK_URL, json=payload, timeout=30)


def thread_id_for(onboarding_id: int) -> str:
    return f"onboarding-{onboarding_id}"


def _callback_payload(onboarding_id: int, result: dict) -> dict:
    contract = result["contract_extraction"]
    w9 = result["w9_extraction"]

    payload = {
        "onboarding_id": onboarding_id,
        "company_name": contract.company_name,
        "tax_id": w9.tax_id,
        "payment_terms": contract.payment_terms,
        "liability_clauses": contract.liability_clauses,
    }

    if "__interrupt__" in result:
        payload["status"] = "needs_review"
        payload["thread_id"] = thread_id_for(onboarding_id)
        payload["explanation"] = result["__interrupt__"][0].value["explanation"]
    else:
        payload["status"] = "approved"

    return payload


async def run_agent_run(onboarding_id: int, document_paths: dict[str, str]) -> None:
    contract_text = read_document(document_paths["contract"])
    w9_text = read_document(document_paths["w9"])

    async with get_checkpointer() as checkpointer:
        await checkpointer.setup()
        graph = build_graph(checkpointer=checkpointer)
        config = {"configurable": {"thread_id": thread_id_for(onboarding_id)}}
        result = await graph.ainvoke(
            {"contract_text": contract_text, "w9_text": w9_text}, config
        )

    send_callback(_callback_payload(onboarding_id, result))


async def run_resume(onboarding_id: int, decision: str) -> None:
    async with get_checkpointer() as checkpointer:
        graph = build_graph(checkpointer=checkpointer)
        config = {"configurable": {"thread_id": thread_id_for(onboarding_id)}}
        result = await graph.ainvoke(Command(resume=decision), config)

    contract = result["contract_extraction"]
    w9 = result["w9_extraction"]

    send_callback(
        {
            "onboarding_id": onboarding_id,
            "status": result["decision"],
            "company_name": contract.company_name,
            "tax_id": w9.tax_id,
            "payment_terms": contract.payment_terms,
            "liability_clauses": contract.liability_clauses,
            "explanation": result.get("explanation"),
        }
    )


@app.post("/trigger", status_code=202)
def trigger(request: TriggerRequest, background_tasks: BackgroundTasks) -> dict:
    background_tasks.add_task(
        run_agent_run, request.onboarding_id, request.document_paths
    )
    return {"accepted": True, "onboarding_id": request.onboarding_id}


@app.post("/resume", status_code=202)
def resume(request: ResumeRequest, background_tasks: BackgroundTasks) -> dict:
    background_tasks.add_task(run_resume, request.onboarding_id, request.decision)
    return {"accepted": True, "onboarding_id": request.onboarding_id}
