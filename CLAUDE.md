# document_compliance_engine — Claude working instructions

> Read PRINCIPLES.md and CONTEXT.md before touching any code.

---

## Architecture in one paragraph

One Elixir release. `DocumentComplianceEngine.Agent` (`apps/document_compliance_engine/lib/document_compliance_engine/agent/`) is
the agent brain — a plain module tree, not a separate application — driven by
Oban: webhook → Oban job → `Agent.Run.trigger/2` runs the pipeline to completion
*inside* that job → the result is written back to `AgentRuns` via a direct
function call, never HTTP. The job process is what keeps the web/LiveView side
unblocked; OTP's own process-level crash isolation is what protects the rest of
the app if the pipeline blows up — a separate deployable was tried first and
deliberately collapsed in because it was only buying independent-deploy/scale
properties this project doesn't need, at the cost of an HTTP hop, a duplicate
`schema_migrations` table, and an extra process to run. See CONTEXT.md's dated
entries for the full history. The two MCP tool servers (`apps/tax_api/`,
`apps/sanctions_db/`) stay genuinely separate OTP applications — they're
external tools, not part of the agent brain.

The repo root is a Mix umbrella (`apps_path: "apps"`) purely for a clear,
consistent directory boundary between the three applications — it is
**not** a standard shared-dependency umbrella. Each app under `apps/` sets
its own `build_path`/`config_path`/`deps_path`/`lockfile` pointing at
itself, so they stay exactly as independent as they were as sibling
top-level directories. **Never run `mix` commands from the repo root** —
`deps: []` there is deliberate, and a root-level `mix deps.get`/`mix test`
triggers Mix's umbrella-wide combined dependency resolution regardless of
those per-app overrides, pulling every app's deps into a stray root
`deps/`/`_build/` and starting all three OTP applications together in one
BEAM node (they collide). Always `cd apps/<name>` first — see CONTEXT.md's
dated entry on the umbrella restructuring.

The Phoenix side is three contexts: `DocumentJobs` owns the ingestion record
and aggregate status (`document_jobs` table, `document_type_slug`),
`AgentRuns` owns each run's extracted/validated output as its own row
(`agent_runs` table, `belongs_to :document_job`) so re-runs keep history
instead of overwriting columns, and `DocumentTypes` (`document_types` table)
is a small config registry of known document types — what a job's
`document_type_slug` refers to, and each type's `extraction_schema`/
`validation_rules`, which `Agent.Run` resolves before invoking the reactor
and the agent pipeline now genuinely interprets (`Extraction.extract_all/2`,
`Checks.validate_all/2`) rather than hardcoding one document's fields.
`thread_id` lives on the `agent_runs` row and is what lets a human approval
in LiveView resume a specific paused agent run. Don't re-litigate the
context split without a real reason. See CONTEXT.md's dated entries:
`DocumentJobs` was `Onboardings` until the data model was generalized beyond
the vendor-contract-plus-W9 case it started as, and the agent pipeline
itself — renamed `OnboardingReactor` → `DocumentReactor` at the point it
actually became document-type-generic — was generalized in a later pass,
proven against a second real document type (`invoice`), not just reshaped
config.

---

## Principles

Follow **PRINCIPLES.md** exactly. Key reminders:

- `document_jobs.ex` / `agent_runs.ex` / `document_types.ex` contain **only `defdelegate`** — no logic
- All `Repo.*` calls for a context's table live exclusively in that context's `repository.ex`
- No context ever queries another's schema directly — only via its public API
  (`DocumentJobs.*` / `AgentRuns.*` / `DocumentTypes.*`)
- `TriggerAgentRun`/`ResumeReview` call `DocumentComplianceEngine.Agent.Run.trigger/2` and
  `.resume/3` directly — no HTTP, no Req, no controller. `Agent.Run` reports its result
  back via `AgentRuns.handle_agent_callback/1` (also a direct call), never the other way
  around — `Agent.*` depends on `AgentRuns`'s public API, `AgentRuns` never depends on `Agent`
- Actions (`actions/*.ex`) coordinate repository + another context's public API + `Agent.Run`
  calls — never call `Repo.*` directly themselves
- LiveView `handle_event` callbacks are ≤ 5 lines — delegate to `DocumentJobs`/`AgentRuns` immediately
- Return `{:ok, result} | {:error, reason}` from every context function
- Bang functions (`get_document_job!/1`) only in LiveView assigns — never in business logic

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

## Application layout

An umbrella root for directory clarity only (see "Architecture in one
paragraph" above — not a shared-dependency umbrella), with three fully
independent apps underneath: one Mix project for the whole control plane +
agent brain, plus two genuinely separate OTP applications for the external
mock tools:

```
mix.exs                         # umbrella root — apps_path only, deps: []
apps/
  document_compliance_engine/             # this Phoenix app — control plane AND agent brain
    mix.exs                       # own deps/build/config/lockfile, self-contained
    lib/document_compliance_engine/
      document_jobs/               # ingestion context (was `onboardings/` — see CONTEXT.md)
      document_types/              # document-type config registry — slug, name, extraction_schema,
                                    # validation_rules; resolved by Agent.Run and interpreted by
                                    # Extraction/Checks — genuinely read by the agent pipeline
      agent_runs/                  # agent-run context — workers/actions call Agent.Run directly
      system_health.ex             # operational snapshot for the dashboard — not a context,
                                    # no table; reads Oban's table directly + AgentRuns' public API
      agent/                       # the agent brain, a plain module tree, NOT a separate app
        document_reactor.ex         # the pipeline, as Reactor steps (document-type-generic)
        schemas/                    # Ecto embedded schemas for structured LLM output
        checks.ex                   # interprets validation_rules: entity-match + the two MCP tools
        mcp_client.ex               # JSON-RPC-over-HTTP client for the tool servers
        run.ex                      # trigger/resume, reports via AgentRuns.handle_agent_callback/1
        checkpoint/                  # schema + repository for the halted-run checkpoint
        evals/                      # fixtures, deterministic tier, LLM judge
    lib/mix/tasks/eval.run.ex     # mix eval.run
    lib/document_compliance_engine_web/
    priv/repo/migrations/         # includes the checkpoint table (own Postgres schema, see below)
  tax_api/                       # separate OTP app exposing MCP (port 8010), own mix.exs
  sanctions_db/                  # separate OTP app exposing MCP (port 8011), own mix.exs
```

The checkpoint table (`agent_checkpoints.run_checkpoints`) shares `DocumentComplianceEngine.Repo`
now but still lives in its own Postgres schema, not `public`, via `@schema_prefix` on the
Ecto schema and `prefix:` in its migration — keeps "don't let checkpoint tables leak into
business-domain migrations" true even with one shared Repo.

### Agent-brain gotchas

- **The `:gate`/`:finalize` split in `agent/document_reactor.ex` is load-bearing.** Reactor
  caches a halted step's `{:halt, value}` as its final result and never re-runs it, so
  the human's decision must be consumed by a *downstream* step. Merging them compiles
  fine and silently returns the stale halt value instead of the reviewer's decision.
- **Resume requires every original input re-supplied**, not just the new one — that's why
  the checkpoint row stores `inputs` (including `documents`/`extraction_schema`/
  `validation_rules`, not just the decision) alongside the serialized reactor.
- **`extraction_schema`/`validation_rules` are resolved once in `Agent.Run`, before
  `Reactor.run/2` is called — not looked up as a Reactor step.** It's a static, idempotent
  config read with no pause/retry need, and keeping it outside Reactor keeps the
  checkpoint's stored `inputs` self-contained for resume, same as every other input.
- **Don't swap the MCP client for `hermes_mcp`'s client.** It passes `transport_opts` as a
  per-request Finch option, which Finch >= 0.21 rejects; the only Req old enough to hold
  Finch back has published CVEs. The two `apps/tax_api` and `apps/sanctions_db` apps use
  `hermes_mcp` (unaffected — server side, not client); `agent/mcp_client.ex` is deliberately
  hand-rolled on Req.
- **`Agent.Run.trigger/3` runs the pipeline synchronously** — by design. It's only ever
  called from inside `TriggerAgentRunWorker`/`ResumeAgentRunWorker` (already off the
  web/LiveView process via Oban), so there's no separate async hop needed the way there
  was when this was an HTTP call to a different process. Never call `Agent.Run.*` from a
  controller or LiveView `handle_event` directly.
- **`Agent.Run` always reports `:ok`**, even when writing the result back to `AgentRuns`
  fails — logged, not propagated to the Oban job. An Oban retry re-runs the *whole*
  pipeline from scratch (re-extraction included) and would hit the checkpoint's unique
  `thread_id` constraint on a halt; swallowing is deliberately safer than that cascade.
- External calls (extraction, entity match, both MCP tools, explanation drafting, the eval
  judge, and the `AgentRuns.handle_agent_callback/1` report itself) are overridable via
  `Application.get_env(:document_compliance_engine, :agent_*)` so tests need no API keys or running
  tool servers. See `apps/document_compliance_engine/test/support/agent_fakes.ex`.

---

## Idempotency and PII — non-negotiable

- Every webhook ingestion computes a hash of the raw payload and checks it against the
  unique `idempotency_key` index **before** creating a row or writing to storage
- Tax ID is stored via an encrypted Ecto type — never add a plaintext Tax ID column or
  log the raw Tax ID value

---

## Pre-commit

Run before committing, from inside the app you touched — `cd apps/document_compliance_engine`,
`cd apps/tax_api`, or `cd apps/sanctions_db` first, never from the repo root:

```
mix precommit
```

This runs: `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`.

Each of the two MCP server applications defines the same `precommit` alias — run it in
whichever ones you touched (`apps/tax_api/`, `apps/sanctions_db/`), in addition to the
main app's, if you touched those.

`mix dialyzer` is set up separately (not part of `precommit` — the first PLT build is
slow, ~1 min; reruns are fast, a few seconds). Run it after touching `@spec`s or schema
types. Every schema module must declare `@type t` — Ecto doesn't generate one, and a
`@spec` referencing `SomeSchema.t()` without it is a silent `unknown_type` dialyzer
error, not a compile error.

---

## File naming conventions

```
apps/document_compliance_engine/lib/document_compliance_engine/document_jobs/schema/document_job.ex
apps/document_compliance_engine/lib/document_compliance_engine/document_jobs/actions/ingest_webhook.ex
apps/document_compliance_engine/lib/document_compliance_engine/document_jobs/actions/list_with_latest_run.ex
apps/document_compliance_engine/lib/document_compliance_engine/document_jobs/repository.ex
apps/document_compliance_engine/lib/document_compliance_engine/document_jobs/idempotency.ex
apps/document_compliance_engine/lib/document_compliance_engine/document_jobs.ex

apps/document_compliance_engine/lib/document_compliance_engine/document_types/schema/document_type.ex
apps/document_compliance_engine/lib/document_compliance_engine/document_types/repository.ex
apps/document_compliance_engine/lib/document_compliance_engine/document_types.ex

apps/document_compliance_engine/lib/document_compliance_engine/agent_runs/schema/agent_run.ex
apps/document_compliance_engine/lib/document_compliance_engine/agent_runs/actions/trigger_agent_run.ex
apps/document_compliance_engine/lib/document_compliance_engine/agent_runs/actions/handle_agent_callback.ex
apps/document_compliance_engine/lib/document_compliance_engine/agent_runs/actions/resume_review.ex
apps/document_compliance_engine/lib/document_compliance_engine/agent_runs/workers/trigger_agent_run_worker.ex
apps/document_compliance_engine/lib/document_compliance_engine/agent_runs/workers/resume_agent_run_worker.ex
apps/document_compliance_engine/lib/document_compliance_engine/agent_runs/repository.ex
apps/document_compliance_engine/lib/document_compliance_engine/agent_runs.ex

apps/document_compliance_engine/lib/document_compliance_engine/agent/run.ex
apps/document_compliance_engine/lib/document_compliance_engine/agent/document_reactor.ex
apps/document_compliance_engine/lib/document_compliance_engine/agent/checkpoint/repository.ex
apps/document_compliance_engine/lib/document_compliance_engine/agent/checkpoint/schema/run_checkpoint.ex

apps/document_compliance_engine/lib/document_compliance_engine_web/controllers/webhook_controller.ex
apps/document_compliance_engine/lib/document_compliance_engine_web/live/dashboard_live.ex
apps/document_compliance_engine/lib/document_compliance_engine_web/live/review_live.ex
```
