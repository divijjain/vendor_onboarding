# Context: Agentic Vendor Onboarding & Compliance Pipeline

This file is a handoff/reference doc for continuing this project in Claude Code. It captures every architectural decision made so far, the reasoning behind each, and what's still open. Read this before writing code — it exists so the build doesn't drift from what was actually decided.

## Origin and goal

Portfolio project intended to demonstrate enterprise integration, agent orchestration, and rigorous evaluation — the skills that distinguish a "cool AI demo" from a system a business could actually run. Plays to existing Elixir/Phoenix background (used elsewhere for `personal_trade`, a Nifty 50 trading dashboard, and general Elixir tooling work) by using Phoenix as the durable orchestration layer wrapping a Python/LangGraph agent core.

## Decided architecture (do not re-litigate without reason)

### High-level flow

1. Vendor sends an email containing a PDF contract + W-9 tax form (simulated payload).
2. **Phoenix webhook** receives it, computes an idempotency key (hash of raw payload) to reject duplicate processing, stores raw documents in S3 (or local equivalent).
3. Phoenix writes a `vendor_onboarding` row (status: `received`) and **enqueues an Oban job** — does NOT call the Python service synchronously (would block the request process for a multi-second-to-minute agent run).
4. The Oban job makes an **async call** to a Python/FastAPI service wrapping a LangGraph graph, passing a `job_id`.
5. **Agent 1 (extraction)**: parses PDF contract + W-9, extracts Company Name, Tax ID, Payment Terms, Liability Clauses into a strict Pydantic schema.
6. **Agent 2 (validation)**: calls two **separate MCP tool servers** — a mock Tax API (validates Tax ID) and a mock Sanctions Database (screens vendor) — and compares extracted entities across documents.
7. **Decision branch**:
   - All checks pass — auto-approve, write status back.
   - Discrepancy found (e.g. name mismatch between contract and W-9) — agent drafts an explanation, workflow **interrupts** (LangGraph `interrupt`), state is **checkpointed to Postgres** (not in-memory — must survive a Python process restart).
8. Python service **calls back** into a Phoenix webhook endpoint (or emits to a queue Phoenix consumes) with the result and, if paused, the `thread_id`.
9. Phoenix stores the `thread_id` on the `vendor_onboarding` row, updates status, broadcasts via **Phoenix PubSub** to a **LiveView** dashboard.
10. Human reviews in LiveView, approves — Elixir makes an async call to Python's **resume(thread_id)** endpoint — LangGraph resumes from checkpoint — workflow completes — status written back — PubSub updates UI.

### Key decisions and rationale (so Claude Code doesn't reintroduce the mistakes these fix)

- **No synchronous Phoenix → LangGraph call.** Async via Oban + callback, always. This is the single most important correction from the initial design.
- **LangGraph checkpointer must be Postgres-backed**, not the default in-memory one — otherwise a paused HITL workflow silently dies on a process restart, undermining the entire "durable pause" claim. Shares the same Postgres instance Ecto uses, but in its **own schema, managed by LangGraph's own setup** — not by Ecto migrations (decided, see below).
- **`thread_id` lives in the Elixir `vendor_onboarding` row.** This is what lets a human action in Phoenix trigger a specific resume on the Python side. Without storing this, "sends an alert for human review" is just a status flag with no real resumability.
- **MCP is two separate MCP servers**, not two functions in-process — built as real, separate FastAPI processes (decided, see below). Be ready to justify MCP over plain function-calling in interviews/README: for exactly two fixed mock tools, function-calling would work identically — MCP's value here is demonstrating the pattern that scales to N real tools, not a functional necessity at this scale. State this honestly rather than keyword-stuffing.
- **Idempotency key on webhook ingestion** (hash of raw payload) to handle vendor email retries/duplicates without double-processing.
- **PII handling**: encryption-at-rest for the document store, access-controlled storage for extracted Tax IDs in Postgres. Don't leave this as a plaintext column — it's a real gap for a project whose whole pitch is compliance.
- **Eval harness calls the Python/LangGraph service directly**, bypassing the full Elixir stack, so agent-quality evaluation is isolated from integration-latency/correctness. Those are different concerns and should be tested separately.

## Evaluation design (decided)

Two-tier, not "LLM-as-judge for everything":

1. **Deterministic checks** (no LLM): Tax ID extracted verbatim present in source document text (this produces the actual hallucination-rate number); Pydantic schema validation passes.
2. **LLM-as-judge checks** (DeepEval `GEval`): entity-mapping correctness under formatting variation; whether the agent's drafted mismatch explanation is actually grounded in the real discrepancy. **Judge model must differ from the agent model** — avoid self-grading inflation. Decided: **agents run on GPT-4o-mini, judge runs on Claude Sonnet** (different providers, not just different checkpoints of the same model).

**20 synthetic test documents, deliberately structured** (not randomly generated):
- 10 clean — should auto-approve
- 5 with genuine entity mismatch — should flag (true positives)
- 3 with subtle formatting difference that is NOT a real mismatch — tests false-positive rate (this is what makes "100% accuracy" a credible claim rather than cherry-picked)
- 2 with missing/malformed fields — tests graceful degradation

## Decisions resolved (previously "Open / not yet decided")

- **Payment Terms / Liability Clauses schema**: free-text fields (`:string`/`:text` on the Elixir side, `str` in the Pydantic schema), validated via LLM-judge (DeepEval `GEval`) rather than strict sub-schemas or typed parsing — these fields are inherently less structured than Company Name / Tax ID and forcing a rigid schema would just produce brittle extraction failures.
- **Model split**: Agent 1 (extraction) and Agent 2 (validation) run on GPT-4o-mini; the DeepEval judge runs on Claude Sonnet. Satisfies the anti-self-grading requirement above with an actual cross-provider split, not just a cross-checkpoint one.
- **MCP servers**: built as two real, separate FastAPI processes under `agent_service/mcp_servers/` (`tax_api/`, `sanctions_db/`), each exposing an MCP tool interface — not simulated inline. The README's description of "two separate MCP servers" is therefore literally true, not aspirational.
- **LiveView review scope**: the paused-review detail view shows a side-by-side contract vs. W-9 field diff (highest-value addition, since name-mismatch is the headline HITL scenario) alongside the agent's drafted explanation and an approve action.
- **Postgres schema ownership**: LangGraph manages its own checkpointer schema/migrations independently (own schema, e.g. `langgraph`, in the same Postgres instance) — Ecto migrations never touch checkpointer tables. Keeps the two stacks decoupled; upgrading LangGraph won't require hand-tracking its internal schema changes in Ecto.

## Open / not yet decided

- Whether document storage in dev is local disk vs. real S3 from day one — plan is to build the storage interface so this is a config swap, defaulting to local disk for early development speed, and revisit before any deploy.
- Exact encryption-at-rest mechanism for the Tax ID column (e.g. `Cloak.Ecto` custom Ecto type vs. Postgres-native column encryption) — needs a decision when the schema/migration is actually written.

## Suggested build order

1. Ecto schema + migrations for `vendor_onboarding` (status, thread_id, extracted fields, timestamps).
2. Phoenix webhook endpoint + idempotency check + S3/local storage, minimal (no AI yet) — confirm the ingestion path end to end with a stub Oban job.
3. Oban job that calls a stub Python endpoint (returns canned JSON) — confirm the async round-trip and callback path work before adding any agent logic.
4. Python/FastAPI service skeleton + LangGraph graph with Agent 1 only (extraction), Postgres checkpointer wired in even though nothing pauses yet.
5. Add Agent 2 + the two MCP mock servers + the decision branch + `interrupt`.
6. Wire LiveView: display status, show paused reviews, implement the resume action.
7. Build the 20 synthetic test documents (structured per the table above) and the DeepEval harness, run it directly against the Python service.
8. Write up eval results in `README.md`, replacing the placeholder metrics table.

See `/Users/divij/.claude/plans/check-files-and-come-harmonic-hellman.md` for the session that scaffolded this project and the specific conventions (from `dentos`/`better_me`) it was built to match.
