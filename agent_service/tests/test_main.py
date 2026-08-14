from fastapi.testclient import TestClient

import app.main as main
from app.schemas import ContractExtraction, W9Extraction


class _FakeCheckpointer:
    async def setup(self):
        pass


class _NullContextManager:
    async def __aenter__(self):
        return _FakeCheckpointer()

    async def __aexit__(self, *exc_info):
        return False


def _fake_send_callback(sent: dict):
    async def send(payload) -> None:
        # Matches the real send_callback's exclude_none=True dump — a
        # CallbackPayload's unset optional fields shouldn't show up as
        # explicit None keys.
        sent.update(payload.model_dump(exclude_none=True))

    return send


def test_trigger_accepts_and_schedules_the_agent_run(monkeypatch):
    calls = []
    monkeypatch.setattr(
        main,
        "run_agent_run",
        lambda onboarding_id, document_paths: calls.append((onboarding_id, document_paths)),
    )

    client = TestClient(main.app)
    response = client.post(
        "/trigger",
        json={"onboarding_id": 42, "document_paths": {"contract": "c.pdf", "w9": "w.pdf"}},
    )

    assert response.status_code == 202
    assert response.json() == {"accepted": True, "onboarding_id": 42}
    assert calls == [(42, {"contract": "c.pdf", "w9": "w.pdf"})]


def test_resume_accepts_and_schedules_the_resume(monkeypatch):
    calls = []
    monkeypatch.setattr(
        main,
        "run_resume",
        lambda onboarding_id, thread_id, decision: calls.append(
            (onboarding_id, thread_id, decision)
        ),
    )

    client = TestClient(main.app)
    response = client.post(
        "/resume",
        json={"onboarding_id": 42, "thread_id": "onboarding-42", "decision": "approved"},
    )

    assert response.status_code == 202
    assert calls == [(42, "onboarding-42", "approved")]


async def test_run_agent_run_sends_an_approved_callback_when_everything_checks_out(
    tmp_path, monkeypatch
):
    contract_path = tmp_path / "contract.pdf"
    w9_path = tmp_path / "w9.pdf"
    contract_path.write_text("contract text")
    w9_path.write_text("w9 text")

    contract_extraction = ContractExtraction(
        company_name="Acme Corp", payment_terms="Net 30", liability_clauses="Standard."
    )
    w9_extraction = W9Extraction(company_name="Acme Corp", tax_id="12-3456789")

    class FakeGraph:
        async def ainvoke(self, state, config):
            return {
                **state,
                "contract_extraction": contract_extraction,
                "w9_extraction": w9_extraction,
                "decision": "approved",
            }

    monkeypatch.setattr(main, "build_graph", lambda checkpointer=None: FakeGraph())
    monkeypatch.setattr(main, "get_checkpointer", lambda: _NullContextManager())

    sent = {}
    monkeypatch.setattr(main, "send_callback", _fake_send_callback(sent))

    await main.run_agent_run(7, {"contract": str(contract_path), "w9": str(w9_path)})

    assert sent == {
        "onboarding_id": 7,
        "status": "approved",
        "company_name": "Acme Corp",
        "w9_company_name": "Acme Corp",
        "tax_id": "12-3456789",
        "payment_terms": "Net 30",
        "liability_clauses": "Standard.",
    }


async def test_run_agent_run_sends_a_needs_review_callback_with_thread_id_on_interrupt(
    tmp_path, monkeypatch
):
    contract_path = tmp_path / "contract.pdf"
    w9_path = tmp_path / "w9.pdf"
    contract_path.write_text("contract text")
    w9_path.write_text("w9 text")

    contract_extraction = ContractExtraction(
        company_name="Acme Corp", payment_terms="Net 30", liability_clauses="Standard."
    )
    w9_extraction = W9Extraction(company_name="Totally Different LLC", tax_id="12-3456789")

    class FakeInterrupt:
        value = {"explanation": "Names do not match."}

    class FakeGraph:
        async def ainvoke(self, state, config):
            return {
                **state,
                "contract_extraction": contract_extraction,
                "w9_extraction": w9_extraction,
                "__interrupt__": [FakeInterrupt()],
            }

    monkeypatch.setattr(main, "build_graph", lambda checkpointer=None: FakeGraph())
    monkeypatch.setattr(main, "get_checkpointer", lambda: _NullContextManager())

    sent = {}
    monkeypatch.setattr(main, "send_callback", _fake_send_callback(sent))

    await main.run_agent_run(9, {"contract": str(contract_path), "w9": str(w9_path)})

    assert sent == {
        "onboarding_id": 9,
        "status": "needs_review",
        "thread_id": "onboarding-9",
        "company_name": "Acme Corp",
        "w9_company_name": "Totally Different LLC",
        "tax_id": "12-3456789",
        "payment_terms": "Net 30",
        "liability_clauses": "Standard.",
        "explanation": "Names do not match.",
    }


async def test_run_agent_run_sends_a_failed_callback_instead_of_dying_silently(
    tmp_path, monkeypatch
):
    contract_path = tmp_path / "contract.pdf"
    w9_path = tmp_path / "w9.pdf"
    contract_path.write_text("contract text")
    w9_path.write_text("w9 text")

    class BoomGraph:
        async def ainvoke(self, state, config):
            raise ValueError("simulated extraction failure")

    monkeypatch.setattr(main, "build_graph", lambda checkpointer=None: BoomGraph())
    monkeypatch.setattr(main, "get_checkpointer", lambda: _NullContextManager())

    sent = {}
    monkeypatch.setattr(main, "send_callback", _fake_send_callback(sent))

    await main.run_agent_run(11, {"contract": str(contract_path), "w9": str(w9_path)})

    assert sent["onboarding_id"] == 11
    assert sent["status"] == "failed"
    assert "simulated extraction failure" in sent["explanation"]


async def test_run_agent_run_sends_a_failed_callback_when_a_document_is_missing(monkeypatch):
    sent = {}
    monkeypatch.setattr(main, "send_callback", _fake_send_callback(sent))

    await main.run_agent_run(12, {"contract": "/no/such/file.pdf", "w9": "/no/such/w9.pdf"})

    assert sent["onboarding_id"] == 12
    assert sent["status"] == "failed"


async def test_run_resume_sends_the_final_decision_as_status(monkeypatch):
    contract_extraction = ContractExtraction(
        company_name="Acme Corp", payment_terms="Net 30", liability_clauses="Standard."
    )
    w9_extraction = W9Extraction(company_name="Totally Different LLC", tax_id="12-3456789")

    class FakeGraph:
        async def ainvoke(self, command, config):
            return {
                "contract_extraction": contract_extraction,
                "w9_extraction": w9_extraction,
                "decision": "rejected",
                "explanation": "Names do not match.",
            }

    monkeypatch.setattr(main, "build_graph", lambda checkpointer=None: FakeGraph())
    monkeypatch.setattr(main, "get_checkpointer", lambda: _NullContextManager())

    sent = {}
    monkeypatch.setattr(main, "send_callback", _fake_send_callback(sent))

    await main.run_resume(9, "onboarding-9", "rejected")

    assert sent["status"] == "rejected"
    assert sent["onboarding_id"] == 9
    assert sent["w9_company_name"] == "Totally Different LLC"
    assert sent["explanation"] == "Names do not match."


async def test_run_resume_sends_a_failed_callback_instead_of_dying_silently(monkeypatch):
    class BoomGraph:
        async def ainvoke(self, command, config):
            raise RuntimeError("simulated resume failure")

    monkeypatch.setattr(main, "build_graph", lambda checkpointer=None: BoomGraph())
    monkeypatch.setattr(main, "get_checkpointer", lambda: _NullContextManager())

    sent = {}
    monkeypatch.setattr(main, "send_callback", _fake_send_callback(sent))

    await main.run_resume(13, "onboarding-13", "approved")

    assert sent["onboarding_id"] == 13
    assert sent["status"] == "failed"
    assert "simulated resume failure" in sent["explanation"]
