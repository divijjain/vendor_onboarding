import os

import httpx
from fastapi import BackgroundTasks, FastAPI
from pydantic import BaseModel

app = FastAPI()

PHOENIX_CALLBACK_URL = os.environ.get(
    "PHOENIX_CALLBACK_URL", "http://localhost:4000/webhooks/agent_callback"
)


class TriggerRequest(BaseModel):
    onboarding_id: int
    document_paths: dict[str, str]


def send_callback(onboarding_id: int) -> None:
    # Build-order step 3 stub: no LangGraph yet, just proves the
    # Oban -> trigger -> callback round trip. Step 4 replaces this with a
    # real extraction/validation run and its actual result.
    httpx.post(
        PHOENIX_CALLBACK_URL,
        json={"onboarding_id": onboarding_id, "status": "approved"},
        timeout=10,
    )


@app.post("/trigger", status_code=202)
def trigger(request: TriggerRequest, background_tasks: BackgroundTasks) -> dict:
    background_tasks.add_task(send_callback, request.onboarding_id)
    return {"accepted": True, "onboarding_id": request.onboarding_id}
