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

## 2026-08-16 — generalized the agent pipeline to actually read `DocumentTypes`, proven with a second document type (`invoice`)

The `DocumentJobs`/`DocumentTypes` split (2026-08-15) generalized the *data
model* but deliberately left the agent brain alone — `OnboardingReactor`,
`Extraction`, and `Checks` stayed hardcoded to the one contract+W-9 bundle,
with `extraction_schema`/`validation_rules` sitting in the DB unread. This
entry closes that gap. Scoped deliberately to **two real document types**,
not an abstract N-type framework — full arbitrary genericity would be
speculative work this project doesn't need; two concrete, structurally
different cases (2 documents vs. 1, three validation rules vs. one, with vs.
without entity-match) is what actually proves the abstraction, the same
"don't design for hypothetical future requirements" discipline this file
already applies elsewhere.

- **Config shape formalized**: `extraction_schema` is `%{role => %{field =>
  "string"}}` (only `"string"` supported — both real types only need it).
  `validation_rules` becomes typed rule maps — `entity_match` (compares two
  named fields) or `mcp_tool` (calls `validate_tax_id`/`screen_vendor`
  against one named field) — replacing the old seed's bare `{"tool": ...}`
  entries, which never actually covered the entity-match check at all and
  were never read by anything. A migration reshapes the existing
  `vendor_contract_w9` row's `validation_rules` to the typed format and
  seeds `invoice` (one document, fields `vendor_name`/`invoice_number`/
  `amount`/`due_date`, a single `screen_vendor` rule — no entity-match, no
  tax ID check, reusing both existing MCP tools rather than building a
  third).
- **`Extraction.extract_all/2` replaces the two hardcoded `extract_contract`/
  `extract_w9` functions.** Verified real, not assumed: Instructor genuinely
  supports schemaless Ecto response models (`response_model: %{field:
  :type}`, a plain map — no compiled `Ecto.Schema` module required), which
  is what makes a runtime, DB-configured extraction schema possible at all.
  Roles are extracted concurrently via `Task.async_stream`, preserving the
  wall-clock behavior of what used to be two independent Reactor steps —
  collapsing to one step and handling concurrency internally was the
  deliberate call over building dynamic per-role Reactor steps via
  `Reactor.Builder`, which would add real complexity to the already-fragile
  halt/resume core for no functional upside on a pipeline this shape.
- **`Checks.validate_all/2` replaces the fixed 3-check `validate/1`** with a
  small interpreter over the two rule types above. The two MCP tools stay a
  fixed, known pair — only which document/field feeds them varies by
  document type — so their human-readable failure messages ("Tax ID failed
  validation...", "Sanctions screening hit: ...") stay hardcoded per tool
  name rather than generated generically. `ValidationResult` changed shape
  accordingly: `%{checks: [%{rule:, passed:, detail:}]}`,
  `approved?/1` = `Enum.all?`.
- **`OnboardingReactor` → `DocumentReactor`**, the rename `CLAUDE.md` itself
  flagged as appropriate "at the point the reactor actually becomes
  document-type-generic... in the same change as that work" — closing the
  loop from the earlier decision to leave it alone during the `DocumentJobs`
  rename. New inputs: `document_type_slug`, `documents` (role => text),
  `extraction_schema`, `validation_rules`, `human_decision`. The
  `:gate`/`:finalize` halt-caching split is untouched — still load-bearing,
  still the same failure mode if collapsed. `DocumentTypes` lookup happens
  in `Agent.Run`, *before* `Reactor.run/2` — a static, idempotent config
  read has no pause/retry need, and resolving it outside Reactor keeps the
  checkpoint's stored `inputs` self-contained for resume, exactly like
  every other input already was.
- **Ingestion webhook payload changed shape**, deliberately, since no real
  external caller exists yet: `{"contract": ..., "w9": ...}` (base64) becomes
  `{"document_type_slug": ..., "documents": {role: base64, ...}}`.
  `IngestWebhook` now resolves the `DocumentType`, validates the `documents`
  map's keys exactly match its `extraction_schema` roles, and stores each
  generically instead of two hardcoded keys.
- **PII boundary decision**: `agent_runs` gained a generic `extracted_fields
  :map` column (plain, unencrypted) for document types with no dedicated
  columns of their own — today, `invoice`. Deliberately **not** a home for
  arbitrary future PII: `contract`/`w9` roles still populate the existing
  fixed, dedicated columns exactly as before (`tax_id` stays on its own
  `Cloak`-encrypted column, populated only from the `w9` role, never swept
  into the generic map), and every field `invoice` actually extracts is
  genuinely non-sensitive. This is a deliberate, narrow boundary — generic
  storage for a known-safe field set — not a general PII-aware framework,
  which stays out of scope until a document type that actually needs one
  exists.
- **Verified**: `mix precommit` clean (110 tests, up from 100 — the new
  `invoice` end-to-end scenarios, `Extraction`/`Checks` unit tests, plus
  fixes to every pre-existing test that assumed the old fixed contract+W9
  shape). The documented regression scenarios were re-run, not assumed
  still true: the halted-reactor-survives-`term_to_binary`/`binary_to_term`
  round trip, and resume not re-running a completed extraction step.

## 2026-08-16 — staged (regex-first) entity-match and Tax ID extraction, backed by research

Prompted by a cost/accuracy question, not a bug: every `entity_match` call and every
`tax_id` extraction paid for a full LLM round trip even when the answer was obvious from
the raw strings. Researched rather than guessed — findings and sources in the conversation
transcript, summarized here:

- A JAMIA Open study comparing regex vs. an LLM for a structurally similar extraction task
  (BI-RADS scores from radiology reports) found regex tied the LLM on accuracy (89.20% vs
  87.69%, not statistically significant) at 28,120× the speed — i.e. for a field with a
  genuinely rigid format, regex isn't a cheaper-but-worse fallback, it's strictly better.
- Entity-resolution research shows the reverse for free text: pure string similarity misses
  semantic aliasing entirely (can't know "SBUX" means Starbucks), so the two fields chosen
  here are the two where each method is actually the right tool — `tax_id` (rigid EIN
  format) for regex, company-name comparison (free text, real aliasing) staged through a
  cheap pre-filter with the LLM as the fallback for genuinely ambiguous cases, not replaced
  outright.
- Self-consistency (multiple LLM samples, checked for agreement) was considered and
  deliberately **not** used as the confidence signal — a 2026 paper ("When LLMs Agree, Are
  They Right?") found agreement can come from shared model bias rather than correctness.
  `String.jaro_distance/2` on normalized names was used instead: deterministic, free, and
  directly calibratable against this project's own fixtures.

**`Checks.staged_match/2`** (`agent/checks.ex`): pure function, `String.jaro_distance/2` on
normalized (downcased, trimmed, punctuation-stripped) names. Thresholds weren't guessed —
computed against the eval harness's own 20 fixtures: the "formatting" bucket (same entity,
cosmetic difference) scores 0.82–0.854; the "mismatch" bucket (genuinely different entities)
scores 0.475–0.65. That's a real gap with margin on both sides, and the thresholds
(`0.95`/`0.70`) sit inside it with room to spare rather than splitting it down the middle —
a false auto-match/auto-mismatch on a compliance decision is worse than an extra LLM call,
so the ambiguous band was left deliberately wide. `entity_match/2` tries `staged_match/2`
first and only calls the configured LLM (real or test fake) for the ambiguous middle band —
the staging wraps *around* the existing `agent_entity_match` override seam, so it applies
uniformly whether the LLM is real or faked, and every existing test's outcome was checked
against the calibration data before relying on it (the one true existing test fixture that
used identical strings specifically to force the fake's answer — "entity_match rule fails
and records a detail on mismatch" — had to be changed to a genuinely ambiguous pair, since
identical strings now correctly short-circuit before the fake is ever reached).

**`Extraction.maybe_regex_extract/2`** (`agent/extraction.ex`): resolves `tax_id` directly
when `\d{2}-\d{7}` appears *exactly once* in the source text — zero or multiple matches is
ambiguous and always falls through to the LLM, never guesses. Scoped deliberately to one
field, not generalized to a per-field pattern config in `extraction_schema` yet — proving it
on the one field with a genuinely unambiguous format before extending the config shape to
support arbitrary patterns is the same "prove it before generalizing" discipline the
document-type work itself followed. When `tax_id` resolves, it's removed from what's asked
of the LLM (fewer fields requested, not just a discarded LLM value) and merged back into the
result — for the `invoice`-style case where regex resolves *every* field in a role, the LLM
call is skipped outright.

**Verified**: `mix precommit` clean, 123 tests (110 prior + 13 new: `staged_match/2`'s three
outcomes, `entity_match/2`'s staging-wraps-the-override-seam behavior via a `send`-based spy
proving the fake genuinely isn't called for clear cases, and `maybe_regex_extract/2`'s four
outcomes plus `extract/3`'s regex-then-fallback behavior). `mix dialyzer` unchanged — same 4
pre-existing errors, none new.

## 2026-08-16 — `mix eval.run` run for real; a silently-dropped judge failure turned out to be a real bug

First real end-to-end run, both `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` configured (via a new
local `.env`/`.envrc` loading mechanism — see below) and both mock MCP servers actually
running. Result: 20/20 decision accuracy across all four buckets, entity-match judge tier
1.00 (n=18). Not just repeated: the first run's groundedness score was `avg 1.00 (n=4)`, one
short of the expected `n=5` (all 5 mismatch-bucket fixtures halt and draft an explanation),
and that discrepancy was chased down rather than reported as-is.

**Root cause, not assumed**: `Evals.Run.judge_scores/1` used a `for` comprehension with
`{:ok, %{score: score}} <- [Judge.groundedness(...)]` as a *filter* — a failed judge call
(`{:error, _}`) simply didn't match and silently vanished from the list, indistinguishable
from "this fixture wasn't scorable." Fixed to `partition_judge_results/1`, which buckets
every judge call into `:scores` or `:errors` explicitly — `judge_scores/1`'s return shape
changed from `%{entity_match: [float()], groundedness: [float()]}` to
`%{entity_match: %{scores:, errors:}, groundedness: %{scores:, errors:}}`, and `mix eval.run`
now prints a failure count and the actual error reason instead of a quietly-smaller `n`. The
callback: an eval harness that hides its own failures the same way is exactly the failure
mode this whole project exists to catch on the agent side — noted explicitly, not just fixed
silently.

**The dropped call was a real bug, not a flaky network error.** `Judge.extract_text/1`
assumed the first element of the Anthropic response's `content` list was always the answer
(`%{"content" => [%{"text" => text} | _]}`). Claude Sonnet 5's extended-thinking responses put
a `type: "thinking"` block *ahead of* the `type: "text"` block, so that assumption was simply
wrong under real conditions the test suite (all fakes) never exercised. Fixed to search the
list for the block with `"type" => "text"` rather than assume position; made `extract_text/1`
public specifically so this parsing logic has direct unit coverage (`judge_test.exs`, the
first test file this module ever had) rather than only being reachable through a live API
call. Re-run after the fix: groundedness correctly reports `avg 1.00 (n=5)`, no errors.

**`.env`/`.envrc` loading added** (`config/config.exs`), since this surfaced while getting
real keys configured locally: checks for either filename (existing `.env.example` convention
vs. a user's own `.envrc`), strips surrounding quotes from values, and only sets a var if not
already exported in the shell — a no-op in CI/prod where secrets come from the real
environment. Both filenames were already gitignored (a user edit had swapped `/.env` for
`/.envrc` in `.gitignore` rather than adding to it; both are now covered). One incidental
finding while wiring this in: `dashboard_live_test.exs`'s system-health-panel test assumed
the two mock MCP servers are never running during `mix test` — true in CI, false the moment
someone actually has them running locally per the README's own instructions. Fixed to stub
the health check the same way `system_health_test.exs` already does, and moved the whole
module to `async: false` since `Application.put_env` is global state shared with that other
test file — verified stable across repeated runs with both mock servers actually up.

**Verified**: `mix precommit` clean, 128 tests (123 prior + 4 new `judge_test.exs` cases + 1
new `judge_scores/1` failure-surfacing test). Real `mix eval.run` output — 20/20 decisions,
both judge averages at 1.00 with the correct sample sizes — is in the README's Evaluation
section, replacing the placeholder table.

## 2026-08-17 — two ways to manually test a document without hand-signing curl

The dashboard had no way to push a document through the pipeline by hand — the only path in
was the HMAC-signed webhook, and exercising it meant hand-computing an HMAC-SHA256 signature
over a JSON body every time. Added two lighter paths, both reusing the exact same ingestion
code (`DocumentJobs.ingest_webhook/1`), not a parallel one:

**`mix webhook.send <fixture_id>`** (`lib/mix/tasks/webhook.send.ex`) — signs and POSTs one of
`Evals.Fixtures`' 20 fixtures against a running `mix phx.server`. Only `vendor_contract_w9`
fixtures exist to send (`Fixtures` has no `invoice` cases). Verified against a real running
server: `mix webhook.send clean-01` → `201`, job landed `approved` on the dashboard. Adds the
same dialyzer noise `eval.run.ex` already has (`callback_info_missing` +
`Mix.raise/1 does not exist` — dialyzer doesn't have PLT info for the `Mix.Task` behaviour or
`Mix.raise/1`; pre-existing false-positive pattern, not a new class of error) — total dialyzer
errors went from 4 to 7, all the same kind.

**A "Submit a test document" form directly on `DashboardLive`** — the more interesting one,
since the dashboard was previously view/act-only by design (ingestion is supposed to model an
external system pushing documents in, not a human uploading files). Built it anyway as an
explicitly-labeled manual-test affordance, not a redesign of the ingestion model. It calls
`DocumentJobs.ingest_webhook/1` directly with an unsigned payload — legitimate here because the
caller is a trusted in-process LiveView action, not an untrusted network origin; the whole
point of HMAC verification is to authenticate an external caller, which doesn't apply to a
button on the app's own admin dashboard.

Design decisions:
- **`.txt` only, not `.pdf`** — the pipeline reads stored bytes as plain text
  (`Agent.Run.read_documents/2`), a documented gap (`Open / not yet decided`, below). Accepting
  PDFs in the upload form would silently feed the agent binary garbage instead of surfacing
  that gap; `.txt`-only keeps the manual-test tool honest about what the pipeline actually does.
- **Upload roles are hardcoded**, not derived generically from `DocumentTypes.extraction_schema`
  — a small `@upload_roles` list mapping `{ref, document_type_slug, label}` for the two roles
  that exist today (`contract`/`w9` for `vendor_contract_w9`, `invoice` for `invoice`). Mirrors
  the same tradeoff `Agent.Run.@known_roles` already makes elsewhere: proving genericity in the
  pipeline itself was worth it (see the 2026-08-16 entry), but a fully dynamic multi-file
  upload UI (dynamic `allow_upload` refs per arbitrary role, one file-role-picker per staged
  entry) would be over-engineering a manual-test convenience tool for two known types.
- **No separate ingestion path.** The form builds the identical
  `{"document_type_slug":, "documents": {role => base64}}` JSON payload the real webhook
  controller decodes and calls `DocumentJobs.ingest_webhook/1` — same idempotency check, same
  validation, same `AgentRuns.enqueue_trigger/1` at the end. Nothing about the ingestion
  contract changed; only a second, unsigned caller was added.

Tested with real `Phoenix.LiveViewTest.file_input/4` + `render_upload/2` (not just a browser
eyeball) — `dashboard_live_test.exs` gained a test that uploads a real in-memory `.txt` file
for the `invoice` type through the form, submits, and asserts a new `document_job` row exists;
and a second test asserting the "select a type and a file for every required document" error
path when submitting without one. **Verified**: `mix precommit` clean, 130 tests (128 prior +
2 new). `mix dialyzer`: 7 errors total (4 pre-existing + 3 new from `webhook.send.ex`, same
false-positive `Mix.Task`/`Mix.raise` pattern as `eval.run.ex`, not a new error class).

## 2026-08-17 — dashboard redesign: presentable-by-default, engineering telemetry demoted not deleted

The dashboard had grown organically feature-by-feature (status table, then a system-health
panel, then the manual-upload form) with no pass for "what does a customer actually want to
see first." Reworked `DashboardLive`'s layout and `Layouts.app`'s content width without
touching any business logic — pure presentation pass.

**What changed:**
- `Layouts.app`'s `<main>` container went from `max-w-2xl` to `max-w-5xl` — the old width was
  cramping the document table and (on `ReviewLive`) the side-by-side contract/W-9 diff grid;
  benefits both pages.
- Added a summary stats row (Total / Needs review / Approved / Needs attention) computed from
  the already-fetched `@document_jobs` list (`Enum.frequencies_by/2` in a new private
  `status_counts/1` — no new query, no new context function; deliberately a view-layer
  aggregation of data already in hand, not a new business capability).
- `core_components.status_badge/1` now humanizes the status atom (`:needs_review` → "Needs
  review") instead of rendering the raw atom — applies everywhere it's used, including
  `ReviewLive`.
- The system-health panel (BEAM process count, Oban queue depth, MCP up/down) — real
  engineering signal, but not something a compliance-review user needs staring at them —
  moved into a closed-by-default `<details class="collapse">` at the bottom of the page.
  **Demoted, not deleted**: still real data, still one click away, still exercised by the
  existing `system_health_test.exs`/`dashboard_live_test.exs` coverage (a `<details>`
  element's content is present in the server-rendered HTML regardless of open/closed state,
  so no test needed to change to keep covering it).
- The manual-upload card's copy was reworded to drop internal jargon ("manual smoke test",
  "unsigned, internal ingestion") — same underlying mechanism (documented in the entry above),
  framed as the dashboard's primary action instead of a caveat.
- Table columns reordered (Company first, not `ID`) and the id demoted to a small `Ref`
  column; added an empty state ("No documents yet — submit one above").

**Two real test-fragility bugs found and fixed while doing this, not just cosmetic:**
1. Humanizing `status_badge` broke three existing substring assertions that had been relying
   on exact atom text — `"needs_review"`, `"received"`, `"approved"` no longer appear verbatim.
   Worse, `review_live_test.exs`'s `refute html =~ "Approve"` started failing for a subtler
   reason: the humanized "Approved" badge text *contains* "Approve" as a substring, so the
   refute now false-failed even though the Approve *button* was correctly absent. Fixed by
   asserting on `phx-click="approve"` instead of the button's visible text.
2. The new stats panel's static labels ("Needs review", "Approved") made the equivalent
   dashboard assertions vacuously true regardless of any row's real status — a bare
   `html =~ "Approved"` now matches the stat-title even with zero approved rows. Fixed by
   scoping assertions to a specific row's badge class via `has_element?(view, "#document_jobs-N
   .badge-success")` rather than whole-page substring matching. This also incidentally hardened
   the tests against a known, pre-existing Ecto Sandbox `shared: true` (`async: false`) sharp
   edge: `mix test` occasionally showed a leaked row from a concurrently-running `async: true`
   test when the assertion was a bare page-wide substring match — scoping to the actual test's
   own row by DOM id removes that class of flake regardless of cause.

**Verified**: `mix compile --warnings-as-errors` clean; real browser-equivalent check via curl
against a running `mix phx.server` (stat cards, "Submit a document" card, reordered table,
`Ref` column, and the collapsed `system status` `<details>` all present in the rendered HTML);
`mix precommit` clean, 130 tests, run 3x back-to-back with no flake recurrence.

## 2026-08-17 — `ReviewLive` now shows the original documents, not just extracted fields

Real gap in the human-in-the-loop review flow, not cosmetic: a reviewer approving/rejecting a
document_job could previously only see the agent's *extracted* fields and drafted explanation
— never the actual source text the agent extracted them from. There was no way to catch the
agent misreading the source, only to trust its output at face value, which undermines the
entire point of a human checkpoint.

**`Storage` gained a `read/1` callback** alongside the existing `store/2` (`LocalDisk.read/1`
is `File.read/1` — `store/2` already returns an absolute path, so no dir-joining needed on
read, mirroring how a future S3 adapter would round-trip the same key/URI it handed back from
`store/2`). New `DocumentJobs.Actions.ReadDocuments` (`DocumentJobs.read_documents/1`) reads a
document_job's stored files back through `Storage`, sorted by role; best-effort — a role whose
file can't be read (moved, deleted, or a test fixture inserted with `document_paths: %{}`) is
silently skipped rather than failing the whole read, since this is supplementary display for a
human, not the pipeline's source of truth (`Agent.Run.read_documents/2` — a different,
pre-existing function with the same name in a different module — still reads `document_paths`
directly for the pipeline itself; not touched, not unified with this one, deliberately, since
that's a separate refactor with its own tradeoffs, out of scope here).

`ReviewLive` renders each stored document as its own card (`<pre>`, plain text — matches what's
actually stored, no PDF rendering) above the extracted-fields comparison, so the reading order
is source-document-first, extraction-second, which is the order a human actually verifies in.

**Verified**: real end-to-end check against a running `mix phx.server` — `mix webhook.send
clean-03` then `curl`'d `/document_jobs/6`, confirmed both the `contract` and `w9` cards render
their real stored text (`VENDOR SERVICES AGREEMENT`, `FORM W-9`), not just a placeholder.
`mix precommit` clean, 136 tests (130 prior + 6 new: 3 for `ReadDocuments`, 2 for
`Storage.read/1`, 1 for `ReviewLive` rendering real stored documents). `mix dialyzer`: still 7
errors, all pre-existing, none new from this change.

## 2026-08-17 — dashboard rows now always link out, not just needs_review ones

Follow-on gap from the "original documents" addition above: the dashboard's table only showed
a "Review" link when a row's status was `:needs_review` — for every other status
(`:received`, `:processing`, `:approved`, `:rejected`, `:failed`) there was simply no way to
navigate into that row at all. That was fine when `ReviewLive` only showed approve/reject
controls (nothing to do once a decision's made), but once it started showing the original
stored documents too, that page became useful for *any* status, not just an awaiting-review
one — and the dashboard's navigation didn't catch up. Fixed: every row now links to
`/document_jobs/:id`, labeled "Review" when `:needs_review`, "View" otherwise.

**Verified**: `mix precommit` clean, 136 tests — updated the existing dashboard test (which had
explicitly asserted the *absence* of a link for non-`needs_review` rows) to assert the new
labeled-link-on-every-row behavior instead of just deleting the coverage.

## 2026-08-17 — Retry button on `ReviewLive` for a `:failed` document_job

Prompted by a real failed row (`document_job #1`) surfacing in the dashboard, traced to
`Instructor.Adapters.OpenAI.api_key/1` hitting a `case_clause: nil` — `OPENAI_API_KEY` wasn't
configured yet at the time that job originally ran. Confirmed the pipeline itself was fine (a
fresh `mix webhook.send` submission against the same running server came back `Approved`
cleanly); the stale `Failed` row just had no way to be un-stuck, since `Agent.Run` always
reports `:ok` even on failure — by design, to avoid an Oban retry replaying the whole pipeline
and colliding with the checkpoint's unique `thread_id` constraint on a halt (see CLAUDE.md's
"Agent-brain gotchas") — so nothing auto-retries a failure.

**No new context logic needed.** A retry is just calling `AgentRuns.enqueue_trigger/1` again —
the exact function `IngestWebhook.call/1` already calls for the original ingest. The
document_job's `document_paths` and `document_type_slug` are still on the row and the files
are still on disk, so re-triggering re-runs the full pipeline against the same stored
documents; no re-upload, no new ingestion. `ReviewLive` gained a `"retry"` `handle_event` (one
call to `AgentRuns.enqueue_trigger/1`, same shape as the existing `submit_decision/2` for
approve/reject) and a `Retry` button shown only when `@document_job.status == :failed`; the
generic "no longer awaiting review" message now excludes `:failed` too, since a failed row does
have an available action.

**Verified for real, not just via tests**: on the actual running dev server, the Retry button
was confirmed present on `document_job #1`'s real page (`phx-click="retry"` in the rendered
HTML), then the same `enqueue_trigger/1` call the button makes was run directly against it —
job #1 went from `Failed` to `Approved` for real, now that `OPENAI_API_KEY` is correctly
configured. `mix precommit` clean, 137 tests (136 prior + 1 new, covering both the button's
conditional visibility and that clicking it enqueues `TriggerAgentRunWorker` via
`assert_enqueued`).

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

Both prior entries here are resolved and moved to "Decisions resolved" above (storage: `DocumentComplianceEngine.Storage` behaviour, `LocalDisk` adapter, config-swappable per the plan; Tax ID: `Cloak.Ecto` custom type on `agent_runs.tax_id`). This section had gone stale — neither reflected the project's actual current state. The real open item as of 2026-08-16:

- **No real PDF/OCR text-extraction step exists.** `Agent.Run.read_documents/2` reads a stored document's bytes with `File.read/1` and feeds them straight into the extraction prompt as if they're already clean, plain text. Every fixture and test in this project supplies literal text strings, so this has never actually been exercised against a real PDF. Every extraction technique discussed or built so far — the LLM call itself, the regex pre-filter for `tax_id`, the entity-match similarity staging, and the layout-aware/NER/OCR options researched but not built (see the 2026-08-16 staged-extraction entry above) — all assume this gap is already closed. It isn't. Closing it means a real text-extraction step (at minimum a PDF-to-text conversion; a scanned/image PDF would need OCR on top of that) ahead of everything else in `Extraction`, and it's real, separate, currently-unscoped work, not a small addition to the existing pipeline.

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
