import os

import httpx
from dotenv import load_dotenv
from fastapi import BackgroundTasks, FastAPI
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


def read_document(path: str) -> str:
    # Documents are simulated vendor emails, not real binary PDFs — see
    # CONTEXT.md's "(simulated payload)" framing — so plain-text read is enough.
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def send_callback(payload: dict) -> None:
    httpx.post(PHOENIX_CALLBACK_URL, json=payload, timeout=30)


def run_agent_run(onboarding_id: int, document_paths: dict[str, str]) -> None:
    contract_text = read_document(document_paths["contract"])
    w9_text = read_document(document_paths["w9"])

    with get_checkpointer() as checkpointer:
        checkpointer.setup()
        graph = build_graph(checkpointer=checkpointer)
        config = {"configurable": {"thread_id": f"onboarding-{onboarding_id}"}}
        result = graph.invoke(
            {"contract_text": contract_text, "w9_text": w9_text}, config
        )

    extraction = result["extraction"]

    send_callback(
        {
            "onboarding_id": onboarding_id,
            "status": "approved",
            "company_name": extraction.company_name,
            "tax_id": extraction.tax_id,
            "payment_terms": extraction.payment_terms,
            "liability_clauses": extraction.liability_clauses,
        }
    )


@app.post("/trigger", status_code=202)
def trigger(request: TriggerRequest, background_tasks: BackgroundTasks) -> dict:
    background_tasks.add_task(
        run_agent_run, request.onboarding_id, request.document_paths
    )
    return {"accepted": True, "onboarding_id": request.onboarding_id}
