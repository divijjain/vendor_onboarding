# vendor_onboarding — Claude working instructions

> Read PRINCIPLES.md and CONTEXT.md before touching any code.

---

## Architecture in one paragraph

Phoenix is the durable control plane; the Python/FastAPI + LangGraph service under
`agent_service/` is the stateless-per-call agent brain. Phoenix never calls it
synchronously — always webhook → Oban job → async HTTP call → callback webhook.
`thread_id` on the `vendor_onboarding` row is what lets a human approval in LiveView
resume a specific paused LangGraph run. See CONTEXT.md for the full rationale; don't
re-litigate the async/callback shape without a real reason.

---

## Principles

Follow **PRINCIPLES.md** exactly. Key reminders:

- `vendor_onboarding.ex` contains **only `defdelegate`** — no logic
- All `Repo.*` calls live exclusively in `vendor_onboarding/repository.ex`
- All HTTP calls to the Python service live exclusively in `vendor_onboarding/agent_service.ex`,
  built on `Req` (never HTTPoison/Tesla/httpc)
- Actions (`actions/*.ex`) coordinate repository + agent_service calls — never call `Repo.*` or
  `Req.*` directly themselves
- LiveView `handle_event` callbacks are ≤ 5 lines — delegate to `VendorOnboarding` immediately
- Return `{:ok, result} | {:error, reason}` from every context function
- Bang functions (`get_onboarding!/1`) only in LiveView assigns — never in business logic

---

## Elixir / Phoenix rules (from AGENTS.md)

- Use **Req** for HTTP — never HTTPoison, Tesla, or httpc
- LiveView templates begin with `<Layouts.app flash={@flash} ...>`
- Use `<.icon name="hero-x-mark">` — never `Heroicons` modules
- Use `<.input>` component for all form inputs
- **Never** write `<script>` tags in HEEx — use colocated hooks for inline JS
- Always use `:if`, `:for`, `:key` attribute syntax — never `<%= if %>` or `<%= for %>`
- `attr` declarations required on every function component

---

## Two-runtime layout

```
vendor_onboarding/          # this Phoenix app
  lib/vendor_onboarding/
  lib/vendor_onboarding_web/
agent_service/               # separate Python/FastAPI + LangGraph service, own repo-local venv
  app/
    graph.py                 # LangGraph graph definition
    schemas.py                # Pydantic extraction schema
    checkpointer.py           # Postgres checkpointer setup (own schema, own migrations — NOT Ecto's)
  mcp_servers/
    tax_api/                 # separate FastAPI process exposing MCP
    sanctions_db/             # separate FastAPI process exposing MCP
```

The Postgres checkpointer schema is owned by LangGraph's own setup, not Ecto migrations —
decided explicitly to keep the two stacks decoupled. Do not add checkpointer tables to
Ecto migrations.

---

## Idempotency and PII — non-negotiable

- Every webhook ingestion computes a hash of the raw payload and checks it against the
  unique `idempotency_key` index **before** creating a row or writing to storage
- Tax ID is stored via an encrypted Ecto type — never add a plaintext Tax ID column or
  log the raw Tax ID value

---

## Pre-commit

Run before committing:

```
mix precommit
```

This runs: `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`.

---

## File naming conventions

```
lib/vendor_onboarding/schema/vendor_onboarding.ex
lib/vendor_onboarding/actions/ingest_webhook.ex
lib/vendor_onboarding/actions/trigger_agent_run.ex
lib/vendor_onboarding/actions/handle_agent_callback.ex
lib/vendor_onboarding/actions/resume_review.ex
lib/vendor_onboarding/agent_service.ex
lib/vendor_onboarding/repository.ex
lib/vendor_onboarding/idempotency.ex
lib/vendor_onboarding.ex

lib/vendor_onboarding_web/controllers/webhook_controller.ex
lib/vendor_onboarding_web/controllers/agent_callback_controller.ex
lib/vendor_onboarding_web/live/dashboard_live.ex
lib/vendor_onboarding_web/live/review_live.ex
```
