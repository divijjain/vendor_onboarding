# Context: Agentic Vendor Onboarding & Compliance Pipeline

This file is a handoff/reference doc for continuing this project in Claude Code. It captures every architectural decision made so far, the reasoning behind each, and what's still open. Read this before writing code — it exists so the build doesn't drift from what was actually decided.

## Origin and goal

Portfolio project intended to demonstrate enterprise integration, agent orchestration, and rigorous evaluation — the skills that distinguish a "cool AI demo" from a system a business could actually run. Plays to existing Elixir/Phoenix background (used elsewhere for `personal_trade`, a Nifty 50 trading dashboard, and general Elixir tooling work) by using Phoenix as the durable orchestration layer wrapping a Python/LangGraph agent core.

## 2026-08-14 — migrated to all-Elixir (supersedes the polyglot framing below)

The Python/FastAPI + LangGraph service and both Python MCP tool servers were replaced
with three Elixir/OTP applications. **Everything below this section still describes the
intended behavior accurately** — the flow, the decision branch, the durable pause, the
eval design are all unchanged. What changed is the implementation language and the
specific libraries. Read the rest of this file for *why the system works the way it
does*; read this section for *what it's built on now*.

- The "Origin and goal" framing below cites polyglot Elixir+Python integration as part of
  the point. That no longer holds — the demonstration is now Elixir/OTP end to end.
- **Component swaps**: Pydantic → Ecto embedded schemas via `instructor`. LangGraph's
  `StateGraph`/`interrupt()` → [Reactor](https://github.com/ash-project/reactor)'s
  `{:halt, …}`/resume. LangGraph's Postgres checkpointer → one Ecto table
  (`agent_checkpoints.run_checkpoints`) owned by `agent_service`'s own Repo and
  migrations. FastAPI → Plug + Bandit. DeepEval `GEval` → a hand-rolled judge on
  Anthropic's Messages API (same two criteria, same cross-provider anti-self-grading
  property; DeepEval is Python-only and was the one genuinely unportable piece).
- **The wire contract did not change** — same `/trigger` and `/resume` request shapes,
  same callback payload — so the Phoenix app's `lib/` needed no code changes.
- **The checkpointer-schema-ownership decision survives verbatim**, just between two
  Elixir apps now instead of two languages: `agent_service` owns its checkpoint schema
  and migrations; the Phoenix app's Ecto migrations never touch them.
- **Reactor's halt is not LangGraph's interrupt.** A halted step is finished — its halt
  value is cached and it never re-executes. The human's decision therefore has to be
  consumed by a step that hasn't run yet, which is why the pipeline has a `:gate` step
  (halts) and a separate `:finalize` step (reads the decision). Resume also requires all
  original inputs re-supplied. Both verified by spike before building on them; the
  durable-pause claim was re-verified across genuinely separate BEAM instances.
- **`hermes_mcp` is used for the servers but not the client.** Its client passes
  `transport_opts` as a per-request Finch option, which Finch >= 0.21 rejects, and the
  only Req old enough to hold Finch back has published CVEs. The agent talks MCP with a
  small JSON-RPC-over-HTTP client on current Req instead. The "two real, separate MCP
  servers" claim is still literally true.

## 2026-08-14 — collapsed `agent_service` into `vendor_onboarding` (one release)

Follow-up to the migration above, same day. `agent_service` had just become a
second, genuinely separate Elixir deployable (own Mix project, own Repo,
talking to `vendor_onboarding` over HTTP). Discussed directly: OTP already
gives crash isolation *within* one release — a supervised process crashing
doesn't take the rest of the node down — so the HTTP boundary was only
buying independent-deploy/independent-scale properties, which this project
doesn't need. Decided to collapse it into a plain module tree
(`lib/vendor_onboarding/agent/`) and keep the two MCP tool servers as the
only genuinely separate deployables (they're external tools, not part of
"the agent brain," and the whole point of MCP here is demonstrating that
pattern).

- **Oban's job process is now the async boundary** that used to be an HTTP
  call. `TriggerAgentRunWorker`/`ResumeAgentRunWorker` already run off the
  web/LiveView process, so `Agent.Run.trigger/2`/`.resume/3` run the
  pipeline to completion *inside* `perform/1` instead of handing off to a
  second process via HTTP. No new `Task.Supervisor` layer needed — Oban
  already is one.
- **One Ecto Repo, one `schema_migrations` table.** The separate-service
  version had two Repos pointed at the same physical `vendor_onboarding_dev`
  database, both racing the same default `public.schema_migrations` table
  across two codebases — harmless in practice (Ecto migration versions are
  just timestamps) but a real smell, discovered and fixed by the collapse:
  the old `agent_service` checkpoint table and its stray `schema_migrations`
  row were dropped, and `vendor_onboarding`'s own migration now owns
  `agent_checkpoints.run_checkpoints` outright.
- **The checkpoint table still lives in its own Postgres schema**, just via
  `VendorOnboarding.Repo` + `@schema_prefix`/`prefix:` now instead of a
  separate Repo module — same "don't leak checkpoint tables into
  business-domain migrations" property, achieved differently.
- **`Agent.Run` reports results via a direct call to
  `AgentRuns.handle_agent_callback/1`**, not an HTTP callback — same
  function, same string-keyed payload shape, just invoked in-process. Kept
  overridable via `Application.get_env(:vendor_onboarding, :agent_callback_fun, ...)`
  for the same testability reason the old `:callback_fun` override existed.
  Deliberately still returns `:ok` on a report failure rather than
  propagating an error to Oban — a retry would replay the *whole* pipeline
  (re-extraction included) and collide with the checkpoint's unique
  `thread_id` constraint on a halt, which is worse than a logged, swallowed
  error. Preserves the previous callback's exact failure semantics rather
  than "improving" them into a new retry-cascade risk.
- **A real, observable behavior change**: `TriggerAgentRun.call/1` now
  blocks until the whole pipeline finishes (extraction + validation), so by
  the time it returns the onboarding is already at its *final* status
  (approved/needs_review/failed) — not still `:processing` the way it was
  when the real result arrived later via a separate HTTP callback. Tests
  were updated to assert the final status, not the intermediate one.
- **`ResumeReview` now enqueues `ResumeAgentRunWorker`** instead of calling
  the (now-deleted) HTTP client inline from the LiveView `handle_event`
  process — keeps the "never block a web/LiveView process on the agent
  pipeline" principle intact, just enforced by Oban instead of by the HTTP
  call being fire-and-forget.

## 2026-08-15 — hardening pass, then umbrella restructuring

A from-scratch critical read of the post-collapse system (webhook endpoint,
CI, Oban retry policy) turned up three real gaps — signature verification
missing on `POST /webhooks/vendor_onboarding`, no CI enforcing `mix
precommit`, and Oban's retry count on the `agent_runs` queue not tuned for
the checkpoint-collision risk already documented above. All three fixed;
see `README.md`'s "2026-08-14 hardening pass" Status entry for details
(webhook HMAC signature plug, `.github/workflows/ci.yml`, `max_attempts: 3`
on both agent-run workers). `mix dialyzer` was deliberately left out of the
new CI workflow — wiring it in surfaced 4 pre-existing errors unrelated to
this pass; fixing those is separate follow-up work.

Separately, same day: the repo root became a Mix umbrella (`apps_path:
"apps"`). Prompted by a real point of confusion working in the repo —
`mcp_servers/tax_api` and `mcp_servers/sanctions_db` nested visually under
a top-level directory that happened to share its name with the Phoenix app
(`vendor_onboarding`), even though the Mix-project boundary underneath was
always real (each already had its own `mix.exs`, `deps`, `_build`). Two
restructuring options were discussed directly: a standard shared-dependency
umbrella (one root `deps`/`_build`/`mix.lock`/`config`, the textbook Mix
pattern), or `apps/` as a purely visual grouping with each app staying
fully self-contained. Chose the latter — a standard umbrella would have
made `tax_api`/`sanctions_db` start pulling in Phoenix/Ecto/Oban/etc. from
a shared dependency tree they don't need, undoing the actual point of
keeping them genuinely separate deployables that the earlier `agent_service`
collapse decision (above) was careful to preserve.

- **Moved** `mcp_servers/tax_api` → `apps/tax_api`, `mcp_servers/sanctions_db`
  → `apps/sanctions_db`, and the Phoenix app's `lib/`, `test/`, `priv/`,
  `assets/`, `config/`, `mix.exs`, `mix.lock`, `.formatter.exs`, `.gitignore`
  → `apps/vendor_onboarding/`. Root-level docs (`README.md`, `CLAUDE.md`,
  `CONTEXT.md`, `PRINCIPLES.md`, `AGENTS.md`) and `.github/` stay at the repo
  root, above the three apps.
- **Each app's `mix.exs` explicitly sets its own `build_path`, `config_path`,
  `deps_path`, and `lockfile`** (all pointing at itself, e.g. `"deps"` not
  `"../../deps"`) — this is what keeps them self-contained despite nesting
  under `apps_path`. Without these overrides, Mix's default umbrella
  behavior for an app nested under `apps/` is to redirect all four to the
  shared umbrella-root locations automatically.
- **A real gotcha, found by testing rather than assumed away**: even with
  those per-app overrides in place, running a `mix` command *from the
  umbrella root itself* (`mix deps.get`, `mix test`, etc., not `cd`'d into
  any app) still triggers Mix's umbrella-wide combined dependency
  resolution — it fetched every app's deps into a stray root `deps/`/
  `_build/` (including `reactor`/`instructor`'s transitive deps, which have
  nothing to do with the two MCP servers) and then tried to start all three
  OTP applications together in one BEAM node, which collided (swoosh's
  hackney adapter missing, port conflicts). The per-app path overrides only
  take effect when Mix is invoked from inside that app's own directory.
  Root-level commands are therefore unsupported by design here — `CLAUDE.md`
  states this explicitly, `.github/workflows/ci.yml` always sets
  `working-directory: apps/<name>`, and the root `mix.exs` moduledoc points
  back to this entry. The stray root `deps/`/`_build/`/`mix.lock` were
  deleted, and the root `.gitignore` was extended to guard against them
  reappearing.
- **Verified**: `mix precommit` run independently inside `apps/vendor_onboarding`,
  `apps/tax_api`, and `apps/sanctions_db` — same 88 + 3 + 3 tests passing,
  each app compiling and fetching deps into its own directory, none of them
  touching the other two's `deps`/`_build`.

## 2026-08-15 — generalized `Onboardings` to `DocumentJobs` + `DocumentTypes`

Prompted by a broader reframing of the project as a "document compliance
engine" rather than a vendor-onboarding-specific pipeline: the domain
schema was hardcoded to one document bundle (a contract + a W-9), with no
notion of "what kind of document is this" as a first-class concept. Scoped
this pass deliberately to the **data model only**, decided explicitly
before writing any code:

- **What changed**: `Onboardings` (context, `onboardings` table,
  `Onboarding` schema) renamed to `DocumentJobs` (`document_jobs`,
  `DocumentJob`) throughout — modules, files, directories, function names
  (`get_onboarding/1` → `get_document_job/1`, etc.), the `AgentRuns` FK
  (`belongs_to :vendor_onboarding` → `belongs_to :document_job`,
  `vendor_onboarding_id` → `document_job_id`), and the LiveView routes
  (`/onboardings` → `/document_jobs`). A new `DocumentTypes` context
  (`document_types` table: `slug`, `name`, `extraction_schema` map,
  `validation_rules` array of maps) was added as a config registry, and
  `document_jobs` gained a `document_type_slug` column referencing it.
  `DashboardLive` gained a document-type filter.
- **What deliberately did *not* change**: the agent pipeline. `Extraction`,
  `Checks`, and `OnboardingReactor` (still so named — see below) still
  only know how to extract a contract + a W-9 into their two fixed Ecto
  embedded schemas; `document_type_slug` isn't read by any of them yet.
  The migration seeds exactly one `document_types` row
  (`vendor_contract_w9`) and every `document_job` defaults onto it, so
  behavior is unchanged — this is additive, not a rewrite. Making
  extraction/validation genuinely vary by document type means teaching
  `Instructor.chat_completion` to build a response model from a
  *runtime* `extraction_schema` instead of a compile-time Ecto embedded
  schema — a real, separate piece of engineering, decided against doing
  in the same pass as a mechanical rename.
- **`OnboardingReactor` was deliberately left unrenamed.** It's the agent
  pipeline's own module, describing the workflow it runs (still, today,
  the vendor-onboarding contract+W9 flow) rather than the `DocumentJobs`
  context — renaming it would have been scope creep into the agent brain
  this pass explicitly avoided touching.
- **A real bug caught by compiling, not assumed away**: the checkpoint
  table's Ecto schema (`agent/checkpoint/schema/run_checkpoint.ex`) is
  application code, so its `onboarding_id` field was renamed to
  `document_job_id` along with everything else — but the migration that
  *created* that table is historical and wasn't touched, so it still
  physically created a column named `onboarding_id`. Caught immediately
  by `mix compile --warnings-as-errors` failing on the mismatched
  `@type t`, before it ever reached a test. Fixed by extending the new
  (same-day, not-yet-committed) generalization migration to also rename
  that column — editing a migration already merged into history would
  have been wrong; editing one written earlier in the same session,
  not yet shared, is not.
- **A quieter bug found only by a second, working grep**: the mechanical
  rename used word-boundary regex (`\bOnboarding\b` etc.) specifically so
  it wouldn't corrupt `VendorOnboarding`/`vendor_onboarding` (the app's
  own namespace, camelCase- or underscore-fused with no true word
  boundary before "Onboarding"). That same protection has a blind spot:
  identifiers where `Onboarding(s)` is fused directly into the *next*
  word with no separator — `OnboardingsTest` (a test module name) and
  `OnboardingsRepository` (a local test alias) — have no trailing
  boundary either, so the regex correctly left them alone for the wrong
  reason. Both were caught by a broader, un-scoped `grep -rn "Onboarding"
  | grep -v vendor` sweep after the mechanical pass — a first attempt at
  that same sweep silently produced no output due to a shell-quoting
  issue in a multi-directory invocation and was mistaken for "all clear"
  until a direct `grep` on one already-known-bad file exposed it. Fixed
  both; the working single-command grep form is worth reusing over the
  multi-directory/looped form next time this kind of audit is needed.
- **Verified**: `mix compile --warnings-as-errors` clean, `mix precommit`
  clean, 95 tests passing (88 prior + 6 new `DocumentTypes.Repository`
  tests + 1 new dashboard filter test), migration applied cleanly to both
  dev and test databases with the seeded `vendor_contract_w9` row present
  before the `document_jobs.document_type_slug` NOT NULL constraint was
  added.

## 2026-08-15 — system health panel on the dashboard

Added `VendorOnboarding.SystemHealth` (`apps/vendor_onboarding/lib/vendor_onboarding/system_health.ex`)
and a `DashboardLive` panel showing it: BEAM process count
(`:erlang.system_info(:process_count)`), Oban queue depth (jobs in
`"available"` state), active agent run count, and an HTTP reachability
check against each MCP server.

- **Deliberately not a context.** It has no table of its own — `oban_jobs`
  belongs to Oban, not to `DocumentJobs` or `AgentRuns`, so `SystemHealth`
  reads it directly via `Repo.aggregate`; that's consistent with the rule
  that only a context's own `repository.ex` touches `Repo.*` for *that
  context's table*, not a blanket ban on `Repo.*` anywhere outside
  `document_jobs/agent_runs/document_types`. The one domain figure it
  needs (active agent runs) goes through `AgentRuns.count_active/0` —
  `AgentRuns.Repository`, never queried directly.
- **The MCP health check hits each server's bare root (`/`), not `/mcp`.**
  Hitting `/mcp` would engage the real MCP JSON-RPC handshake
  `Agent.McpClient` uses (`initialize` → `notifications/initialized` →
  `tools/call`) — overkill and semantically wrong for "is the process up
  and accepting HTTP," which is what `Plug.Router`'s catch-all 404 on `/`
  already proves. Any HTTP response (including 404) means up; a
  connection error means down.
- **Overridable the same way the agent's external calls are** —
  `Application.get_env(:vendor_onboarding, :system_health_mcp_check_fun, ...)`
  — so `SystemHealthTest` doesn't need either mock server running to
  assert both branches. `DashboardLiveTest`'s panel test deliberately
  does *not* override it: neither MCP server runs during `mix test`
  (they're separate OTP apps, started manually per the README), so
  asserting both badges render `down` is a real, not mocked, assertion.
- Refreshes every 5 seconds via `Process.send_after/3` from `mount/3`
  when `connected?/1` — same "only schedule timers on the connected
  mount" pattern LiveView docs recommend, so the disconnected initial
  render doesn't leak a timer.
- **Verified**: `mix precommit` clean, 100 tests passing (95 prior + 5
  new: 2 `AgentRuns.count_active/0`, 2 `SystemHealth.snapshot/0`, 1
  dashboard panel render).

## 2026-08-15 — root path and navbar didn't lead anywhere

Found by direct inspection, not assumed: `/` and the persistent navbar
were both still the unmodified `mix phx.new` scaffold — the navbar linked
to phoenixframework.org/GitHub/Phoenix hexdocs, and `/` rendered Phoenix's
own "Peace of mind from prototype to production" landing page. Nothing in
either one pointed at `/document_jobs`. The only way to reach any real
feature was already knowing that URL.

- `PageController.home/2` now redirects to `/document_jobs` instead of
  rendering — this is an internal back-office tool, not a marketing site,
  so a separate landing page at `/` has no job to do. `PageHTML` and its
  template (`page_html/home.html.heex`) were deleted rather than left
  behind as now-unreachable dead code.
- The navbar (`Layouts.app/1`) now links to `/document_jobs` from every
  page (logo + an explicit "Dashboard" link) instead of Phoenix's own
  marketing links; kept the theme toggle.
- **Verified against a real running server, not just the test suite**:
  started `mix phx.server` (on a non-default port — 4000 was already
  occupied by an unrelated project on this machine, left untouched) and
  curled `/` (302 → `/document_jobs`) and `/document_jobs` (200,
  containing both the "Dashboard" nav link and the health panel from the
  entry above) before reporting this done.
- `mix precommit` clean, same 100 tests (the root-path test was rewritten
  to assert the redirect, not added to).

## 2026-08-15 — renamed the app: `VendorOnboarding` → `DocumentComplianceEngine`

The `Onboardings` → `DocumentJobs`/`DocumentTypes` generalization earlier
this day only renamed the *ingestion context*. Everything above it — the
OTP app (`:vendor_onboarding`), the Elixir module namespace
(`VendorOnboarding.*`/`VendorOnboardingWeb.*`), the `apps/vendor_onboarding/`
directory, the dev/test databases — was still the original name, prompted
directly: "the name must also reflect the same." Two scopes were on the
table — branding/docs only, or that plus the full technical rename
(app atom, module namespace, directory, database) — the fuller option was
chosen explicitly.

- **Renamed**: `apps/vendor_onboarding/` → `apps/document_compliance_engine/`
  (and its inner `lib/vendor_onboarding{,_web}/`, `test/vendor_onboarding{,_web}/`
  directories); every `VendorOnboarding`/`vendor_onboarding` token across
  `lib/`, `test/`, `config/*.exs`, `mix.exs`, and the asset pipeline
  (`assets/js/app.js`, `assets/css/app.css` — the `phoenix-colocated/<app>`
  import path is derived from the app name and needed the same rename);
  the dev/test Postgres databases (`vendor_onboarding_dev/_test` →
  `document_compliance_engine_dev/_test`, old ones dropped after the new
  ones were confirmed migrating cleanly); the umbrella root `mix.exs`
  module (`VendorOnboarding.Umbrella.MixProject` →
  `DocumentComplianceEngine.Umbrella.MixProject`); `.github/workflows/ci.yml`'s
  `apps/vendor_onboarding` paths; the navbar text and page `<title>`
  (previously still "Vendor Onboarding"/plain Phoenix defaults — English
  prose with a space, so untouched by the mechanical `VendorOnboarding`/
  `vendor_onboarding` substitution and needed a manual pass); and
  `CLAUDE.md`/`PRINCIPLES.md`, both blanket-substituted since neither
  carries dated history to protect.
- **Deliberately left alone**: the webhook route path
  (`/webhooks/vendor_onboarding`) — it names the one ingestion flow that
  exists today (a vendor's contract + W-9), not the application, and
  wasn't part of what was actually offered/chosen (app atom, module
  namespace, directory, database — not API route naming). Also
  `OnboardingReactor`, for the same reason it survived the `DocumentJobs`
  rename: it's the agent pipeline's own module describing the workflow it
  runs, not the ingestion context.
- **README.md and this file's own dated entries were *not* retroactively
  rewritten.** Every existing dated entry describes what was literally
  true when it was written — and at every one of those points, the app
  really was named `vendor_onboarding`/`VendorOnboarding`. Rewriting them
  would be revisionist, the same principle already applied when
  `Onboardings` became `DocumentJobs` and old entries kept saying
  `Onboardings`. Only this new entry and README's evergreen
  (non-dated) sections — Architecture prose, Tech stack, Local
  development — were updated to the current name.
- **A real mistake, caught before it reached a test.** The rename script
  swept `priv/repo/migrations/*.exs`, which includes fully historical,
  already-applied migrations — corrupting literal Postgres identifier
  strings that describe what was actually run (e.g. the real index name
  `agent_runs_vendor_onboarding_id_index`, derived from a *column* that
  was named `vendor_onboarding_id` for reasons unrelated to the app's own
  name — coincidental string overlap, not the same fact). `mix compile`
  didn't catch this one (it's a valid Elixir file either way — the bug is
  in a runtime SQL string), but `mix ecto.migrate` against a fresh
  database did: renaming a Postgres index that was never actually created
  under its corrupted name would fail outright the moment a real replay
  was attempted. Caught before that by inspection, restored every
  migration file's content from the last commit (`055e22b`, which
  predated this rename), and dropped + recreated both databases from the
  corrected files rather than trusting the state left by the one
  corrupted run. This is the exact discipline `CLAUDE.md`/this file
  already state for migrations — never edit one already applied — just
  violated once, by a blanket find/replace that didn't carve migrations
  out the way the `DocumentJobs` rename's script deliberately had.
- **Verified**: `mix compile --warnings-as-errors` clean, `mix precommit`
  clean, 100 tests passing (unchanged count — a rename, not new
  behavior), both databases dropped and recreated from the corrected
  migrations, `.github/workflows/ci.yml` paths updated to match.

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
