# document_compliance_engine — Elixir design principles

Ported from `better_me`/`dentos`. Applies without change except where
this project's shape differs (an `Agent` module tree calling out to LLMs/MCP
tools instead of multiple LiveView-only domains).

Reference this before writing any new module.

---

## 1. three contexts, each with its own table

Three domains, each a self-contained context with its own schema/table.
Nothing outside a context touches its schema directly — all access goes
through the context's public API (`DocumentJobs.*` / `AgentRuns.*` /
`DocumentTypes.*`).

```
DocumentJobs  — the ingestion record: what came in, its document type
                (`document_type_slug`), and its aggregate status. Owns
                the `document_jobs` table.
AgentRuns     — one row per agent run against a given document job: the
                extracted/validated output, kept as history across
                re-runs instead of overwritten columns. Owns the
                `agent_runs` table (belongs_to :document_job).
DocumentTypes — a small config registry: what document types this system
                knows about (`slug`, `name`), and each type's configured
                `extraction_schema`/`validation_rules`. Owns the
                `document_types` table. Not yet read by the agent
                pipeline — see the note below.
```

This was originally one context/one table (`vendor_onboarding.ex` +
`vendor_onboardings` — the app's literal name at that point in the project's
history, before either rename below). Split into `Onboardings`/`AgentRuns` because the row
conflated "the ingestion record" with "the latest agent run's output" —
overwriting the same columns on every run meant no history, and no real
context boundary existed since there was nothing to draw one around.
`agent_runs` being a real second table is what makes that boundary real,
not just a second module reading the same rows. `Onboardings` was later
renamed to `DocumentJobs` and gained `DocumentTypes` as a data-model
generalization step — accepting a `document_type_slug` per job instead of
being hardcoded to one fixed vendor-contract-plus-W9 shape. **The agent
pipeline itself (`OnboardingReactor`, still so named) was deliberately
left alone in that pass** — it still only implements the one document type
the generalization migration seeded (`vendor_contract_w9`); making
extraction/validation actually vary by `document_type_slug` is a real,
separate rewrite of the agent brain, not done yet. See CONTEXT.md's dated
entry for the full rationale on both splits.

### cross-context rule

**No context reaches into another context's schema.** `AgentRuns`
never queries `document_jobs` directly; it calls `DocumentJobs.get_document_job/1`,
`DocumentJobs.update_status/2`. `DocumentJobs` never queries `agent_runs`
directly; it calls `AgentRuns.get_latest_for_document_job/1`,
`AgentRuns.latest_by_document_job_ids/1`, `AgentRuns.enqueue_trigger/1`.
Neither queries `document_types` directly; both would call
`DocumentTypes.get_document_type_by_slug/1` if they needed type metadata.

**A read model that needs more than one context's data lives in the context
that owns the list, and merges via public API calls — never a query that
joins across schemas.** The dashboard is the example: `DocumentJobs.Actions.ListWithLatestRun`
calls `Repository.list/1` (its own table) and `AgentRuns.latest_by_document_job_ids/1`
(the other context's public API, batched — not N+1), then merges the
two into a plain map. This mirrors better_me's "cross-cutting queries
belong in the owning domain" pattern.

### structure
```
apps/document_compliance_engine/lib/document_compliance_engine/
  repo.ex                        infra — shared by all contexts
  vault.ex / encrypted/binary.ex infra — Cloak encryption (used by AgentRuns' tax_id)
  storage.ex / storage/          infra — document storage boundary (used by DocumentJobs)

  document_jobs/
    schema/document_job.ex        Ecto schema + changesets
    actions/
      ingest_webhook.ex           idempotency check, storage, row creation, job enqueue
      list_with_latest_run.ex     dashboard read model — batches AgentRuns, no N+1
    repository.ex                 all Repo.* calls for `document_jobs`
    idempotency.ex                pure — hash of raw payload
  document_jobs.ex                public API — defdelegate only

  document_types/
    schema/document_type.ex       Ecto schema + changeset
    repository.ex                 all Repo.* calls for `document_types`
  document_types.ex               public API — defdelegate only

  agent_runs/
    schema/agent_run.ex           Ecto schema + changesets
    actions/
      trigger_agent_run.ex        called from the worker — calls Agent.Run.trigger/2, starts a run row
      handle_agent_callback.ex    writes run result, mirrors status onto DocumentJobs, broadcasts PubSub
      resume_review.ex            human approval -> enqueues ResumeAgentRunWorker
    workers/trigger_agent_run_worker.ex   Oban worker + enqueue/1 helper
    workers/resume_agent_run_worker.ex    Oban worker + enqueue/3 helper — calls Agent.Run.resume/3
    repository.ex                 all Repo.* calls for `agent_runs`
  agent_runs.ex                   public API — defdelegate only

  agent/                          the agent pipeline — a module tree, not a separate app;
                                   see CLAUDE.md's "Agent-brain gotchas" for its own rules
```

### rules
- `document_jobs.ex` / `agent_runs.ex` / `document_types.ex` contain only `defdelegate` — nothing else, ever
- Each context's `repository.ex` is the only file that calls `Repo.*` for that context's table
- Action modules call their own context's `Repository.*`, another context's public
  API (`DocumentJobs.*` / `AgentRuns.*` / `DocumentTypes.*`), `DocumentComplianceEngine.Agent.Run.*`,
  and other actions in the same context — never `Repo.*` directly, never another context's
  `Repository.*` or `Schema.*`
- Action modules are private — never called from outside their context
- Pure logic modules (idempotency hashing) have no DB or side-effect dependencies
- Keep action modules focused: if it grows beyond ~30 lines, split it — including
  extracting genuinely pure steps (no DB, no side effects) into their own module,
  the way `decode_payload` in `IngestWebhook` should if it starts pulling the
  action past the guideline (not yet split — flagged here as the next thing
  to do if that action grows further, not done pre-emptively)

### the strict boundary rule
- **`repository.ex` only touches `Repo.*`** — no coordination, no calling another context
- **`actions/*.ex` never calls `Repo.*` directly** — actions call their own `Repository.*`,
  another context's public API, and `DocumentComplianceEngine.Agent.Run.*`
- **Anything that bridges a repo call and a call into the agent pipeline belongs in an action** —
  e.g. `TriggerAgentRun` reads the document job via `DocumentJobs.get_document_job/1`, starts a run via
  `Repository.insert/1`, then calls `Agent.Run.trigger/2` (which reports its result straight back
  to `AgentRuns.handle_agent_callback/1`, not to `TriggerAgentRun`'s return value), then writes
  status back via `DocumentJobs.update_status/2`. That sequencing is coordination.

---

## 2. context design

- `document_jobs.ex` / `agent_runs.ex` / `document_types.ex` contain only `defdelegate` — no `import`, no `alias`, no logic
- Repository and action functions scope to what's available for this app: there's no
  multi-tenant `user_id` here (vendor onboarding is an internal back-office tool), but
  every query still filters by ID/idempotency key explicitly — never fetch unbounded lists
- All context functions return `{:ok, result} | {:error, reason}`

### function naming conventions
```elixir
# DocumentJobs
ingest_webhook(raw_payload)                       # {:ok, document_job} | {:error, :duplicate | :invalid_payload | changeset}
get_document_job(id)                              # {:ok, document_job} | {:error, :not_found}
get_document_job!(id)                             # raises — only in LiveView assigns
list_document_jobs(opts \\ [])                    # returns list, filter/sort in SQL
list_document_jobs_with_latest_run(opts \\ [])    # dashboard read model, delegates to ListWithLatestRun
reload_document_job_row(id)                       # single-row equivalent, for PubSub-triggered reload
update_status(id, status)                         # called by AgentRuns to mirror run status onto the job

# AgentRuns
trigger_agent_run(document_job_id)                # delegates to TriggerAgentRun action
handle_agent_callback(payload)                    # delegates to HandleAgentCallback action
resume_review(document_job_id, decision)          # delegates to ResumeReview action
get_latest_for_document_job(document_job_id)      # {:ok, agent_run} | {:error, :not_found}
latest_by_document_job_ids(ids)                   # %{document_job_id => agent_run} — batched, for lists
enqueue_trigger(document_job_id)                  # Oban enqueue — called by DocumentJobs' IngestWebhook

# DocumentTypes
get_document_type_by_slug(slug)                   # DocumentType.t() | nil
list_document_types()                             # returns list — small config table, no pagination needed
create_document_type(attrs)                       # {:ok, document_type} | {:error, changeset}
```

---

## 3. schema + changeset patterns

- Plain integer primary keys (Ecto default) — no `binary_id`
- `DocumentJob.status` (`Ecto.Enum`: `:received, :processing, :needs_review, :approved, :rejected`)
  is the aggregate status the dashboard/LiveView reads — kept in sync by `AgentRuns`
  via `DocumentJobs.update_status/2`, never written directly from an `AgentRuns` query
- `DocumentJob.document_type_slug` references `document_types.slug` (FK on the non-PK
  unique column, not `document_type_id`) and defaults to `"vendor_contract_w9"` — the
  one type the agent pipeline actually implements today
- `AgentRun.status` (`Ecto.Enum`: `:processing, :needs_review, :approved, :rejected`) is
  that specific run's outcome — a re-run gets a new row, not an overwritten one
- **Tax ID is PII** — encrypt at rest (`Cloak.Ecto` custom type, `DocumentComplianceEngine.Encrypted.Binary`),
  never a plaintext column. Lives on `AgentRun`, not `DocumentJob`. Hard requirement from
  CONTEXT.md, not a nice-to-have.
- Payment Terms / Liability Clauses are free text (`:string`) — not strictly typed,
  validated via the agent's LLM-judge eval tier, not an Ecto changeset rule
- Idempotency key: unique index on `document_jobs`, `hash of raw payload`, checked in
  `DocumentJobs.Repository` before insert

---

## 4. error handling

- All context functions return `{:ok, result} | {:error, reason}`
- Reason is a changeset, an atom (`:not_found`, `:duplicate`, `:not_awaiting_review`), or
  a string (external service error)
- Use `with` for multi-step actions — fail fast, one error path
- Bang functions only in LiveView assigns
- Never rescue in context functions for expected failures; `Agent.McpClient` (Req calls to
  the two MCP tool servers) and the `Instructor.chat_completion` calls are the real external
  boundaries, and the one place `rescue`/timeout handling belongs

---

## 5. performance + query patterns

- Filter/sort in SQL, not `Enum` after the fact
- Index `document_jobs.idempotency_key` (unique), `document_jobs.status`,
  `document_jobs.document_type_slug`, `document_types.slug` (unique),
  `agent_runs.document_job_id`, `agent_runs.thread_id`, `agent_runs.status`
- `AgentRuns.latest_by_document_job_ids/1` batches the dashboard's "latest run per
  document job" lookup in one query (Postgres `DISTINCT ON`-style, via `distinct` +
  matching `order_by`) — never N+1 per row
- Order-by ties: `agent_runs` uses `timestamps(type: :utc_datetime)` (second
  granularity), so "latest run" queries order by `[desc: :inserted_at, desc: :id]`,
  not `inserted_at` alone — two runs created in the same second would otherwise
  tie non-deterministically
- Paginate the LiveView dashboard list — never fetch unbounded document job rows
- `DocumentTypes.list_document_types/0` is unpaginated on purpose — it's a small,
  operator-managed config table, not user-generated data

---

## 6. LiveView structure

- One LiveView for the dashboard (list + status + a document-type filter, calls
  `DocumentJobs.list_document_jobs_with_latest_run/1` and `DocumentTypes.list_document_types/0`
  for the filter's options), one for the review detail (paused case, side-by-side
  contract/W-9 diff, approve action — assigns both `@document_job`
  (`DocumentJobs.get_document_job!/1`) and `@agent_run`
  (`AgentRuns.get_latest_for_document_job/1`), calls each context directly rather than
  through an intermediary)
- `handle_event` callbacks ≤ 5 lines — delegate to `DocumentJobs.*` / `AgentRuns.*` / `DocumentTypes.*` immediately
- PubSub topic per document job row (or a single `"document_compliance_engine"` topic broadcasting
  `{:status_updated, id}`) — dashboard subscribes and reloads the affected row, not the whole list

---

## 7. elixir fundamentals

Same as `better_me`/`dentos`: immutability + pipelines, pattern matching over conditionals,
let it crash (except at the MCP/LLM HTTP boundaries), tagged tuples & `with`, `Enum`/`Stream`
over `for`, `snake_case`/`PascalCase` naming, `?`/`!` suffix conventions.

---

## summary — the checklist

- [ ] Schema is private to its context's `schema/` directory
- [ ] No context aliases or queries another context's `Schema`/`Repository` — only its public API
- [ ] All functions return `{:ok, _} | {:error, _}`
- [ ] No bare `Repo.*` calls outside a context's own `repository.ex`
- [ ] No bare `Repo.*`/coordination calls into the agent pipeline outside `DocumentComplianceEngine.Agent.Run`
- [ ] Tax ID stored via an encrypted Ecto type, never plaintext
- [ ] Idempotency key checked before any row is created
- [ ] `thread_id` is written to the run row on every pause callback — this is what makes resume possible
- [ ] `DocumentJob.status` stays in sync with the latest `AgentRun.status` via `DocumentJobs.update_status/2`
- [ ] LiveView `handle_event` delegates to `DocumentJobs`/`AgentRuns`/`DocumentTypes` within 5 lines
- [ ] Queries filter/sort in SQL, not `Enum`
- [ ] Batched lookups (not N+1) for any list that needs data from more than one context
- [ ] At least one test for the happy path and one for the duplicate/idempotency case
