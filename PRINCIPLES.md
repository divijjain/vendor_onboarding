# vendor_onboarding — Elixir design principles

Ported from `better_me`/`dentos`. Applies without change except where
this project's shape differs (external Python service instead of
multiple LiveView-only domains).

Reference this before writing any new module.

---

## 1. two contexts, each with its own table

Two domains, each a self-contained context with its own schema/table.
Nothing outside a context touches its schema directly — all access goes
through the context's public API (`Onboardings.*` / `AgentRuns.*`).

```
Onboardings   — the ingestion record: what came in, and the onboarding's
                aggregate status. Owns the `onboardings` table.
AgentRuns     — one row per agent run against a given onboarding: the
                extracted/validated output, kept as history across
                re-runs instead of overwritten columns. Owns the
                `agent_runs` table (belongs_to :vendor_onboarding).
```

This was originally one context/one table (`vendor_onboarding.ex` +
`vendor_onboardings`). Split because the row conflated "the ingestion
record" with "the latest agent run's output" — overwriting the same
columns on every run meant no history, and no real context boundary
existed since there was nothing to draw one around. `agent_runs` being
a real second table is what makes the boundary real, not just a second
module reading the same rows.

### cross-context rule

**No context reaches into another context's schema.** `AgentRuns`
never queries `onboardings` directly; it calls `Onboardings.get_onboarding/1`,
`Onboardings.update_status/2`. `Onboardings` never queries `agent_runs`
directly; it calls `AgentRuns.get_latest_for_onboarding/1`,
`AgentRuns.latest_by_onboarding_ids/1`, `AgentRuns.enqueue_trigger/1`.

**A read model that needs both contexts' data lives in the context that
owns the list, and merges via public API calls — never a query that
joins across schemas.** The dashboard is the example: `Onboardings.Actions.ListWithLatestRun`
calls `Repository.list/1` (its own table) and `AgentRuns.latest_by_onboarding_ids/1`
(the other context's public API, batched — not N+1), then merges the
two into a plain map. This mirrors better_me's "cross-cutting queries
belong in the owning domain" pattern.

### structure
```
lib/vendor_onboarding/
  repo.ex                        infra — shared by both contexts
  vault.ex / encrypted/binary.ex infra — Cloak encryption (used by AgentRuns' tax_id)
  storage.ex / storage/          infra — document storage boundary (used by Onboardings)

  onboardings/
    schema/onboarding.ex          Ecto schema + changesets
    actions/
      ingest_webhook.ex           idempotency check, storage, row creation, job enqueue
      list_with_latest_run.ex     dashboard read model — batches AgentRuns, no N+1
    repository.ex                 all Repo.* calls for `onboardings`
    idempotency.ex                pure — hash of raw payload
  onboardings.ex                  public API — defdelegate only

  agent_runs/
    schema/agent_run.ex           Ecto schema + changesets
    actions/
      trigger_agent_run.ex        called from the worker — calls AgentService, starts a run row
      handle_agent_callback.ex    writes run result, mirrors status onto Onboardings, broadcasts PubSub
      resume_review.ex            human approval -> AgentService.resume/1
    workers/trigger_agent_run_worker.ex   Oban worker + enqueue/1 helper
    agent_service.ex              Req-based HTTP client to the Python/FastAPI service
    repository.ex                 all Repo.* calls for `agent_runs`
  agent_runs.ex                   public API — defdelegate only
```

### rules
- `onboardings.ex` / `agent_runs.ex` contain only `defdelegate` — nothing else, ever
- Each context's `repository.ex` is the only file that calls `Repo.*` for that context's table
- Action modules call their own context's `Repository.*`, the *other* context's public
  API (`Onboardings.*` / `AgentRuns.*`), `AgentService.*`, and other actions in the
  same context — never `Repo.*` directly, never the other context's `Repository.*` or `Schema.*`
- Action modules are private — never called from outside their context
- Pure logic modules (idempotency hashing) have no DB or side-effect dependencies
- Keep action modules focused: if it grows beyond ~30 lines, split it — including
  extracting genuinely pure steps (no DB, no side effects) into their own module,
  the way `decode_payload` in `IngestWebhook` should if it starts pulling the
  action past the guideline (not yet split — flagged here as the next thing
  to do if that action grows further, not done pre-emptively)

### the strict boundary rule
- **`repository.ex` only touches `Repo.*`** — no coordination, no HTTP calls, no calling the other context
- **`actions/*.ex` never calls `Repo.*` directly** — actions call their own `Repository.*`,
  the other context's public API, and `AgentService.*`
- **Anything that bridges a repo call and an HTTP call to the Python service belongs in an action** —
  e.g. `TriggerAgentRun` reads the onboarding via `Onboardings.get_onboarding/1`, starts a run via
  `Repository.insert/1`, then calls `AgentService.trigger/1`, then writes status back via
  `Onboardings.update_status/2`. That sequencing is coordination.

---

## 2. context design

- `onboardings.ex` / `agent_runs.ex` contain only `defdelegate` — no `import`, no `alias`, no logic
- Repository and action functions scope to what's available for this app: there's no
  multi-tenant `user_id` here (vendor onboarding is an internal back-office tool), but
  every query still filters by ID/idempotency key explicitly — never fetch unbounded lists
- All context functions return `{:ok, result} | {:error, reason}`

### function naming conventions
```elixir
# Onboardings
ingest_webhook(raw_payload)                    # {:ok, onboarding} | {:error, :duplicate | :invalid_payload | changeset}
get_onboarding(id)                             # {:ok, onboarding} | {:error, :not_found}
get_onboarding!(id)                            # raises — only in LiveView assigns
list_onboardings(opts \\ [])                   # returns list, filter/sort in SQL
list_onboardings_with_latest_run(opts \\ [])   # dashboard read model, delegates to ListWithLatestRun
reload_onboarding_row(id)                      # single-row equivalent, for PubSub-triggered reload
update_status(id, status)                      # called by AgentRuns to mirror run status onto the onboarding

# AgentRuns
trigger_agent_run(onboarding_id)               # delegates to TriggerAgentRun action
handle_agent_callback(payload)                 # delegates to HandleAgentCallback action
resume_review(onboarding_id, decision)         # delegates to ResumeReview action
get_latest_for_onboarding(onboarding_id)       # {:ok, agent_run} | {:error, :not_found}
latest_by_onboarding_ids(ids)                  # %{onboarding_id => agent_run} — batched, for lists
enqueue_trigger(onboarding_id)                 # Oban enqueue — called by Onboardings' IngestWebhook
```

---

## 3. schema + changeset patterns

- Plain integer primary keys (Ecto default) — no `binary_id`
- `Onboarding.status` (`Ecto.Enum`: `:received, :processing, :needs_review, :approved, :rejected`)
  is the aggregate status the dashboard/LiveView reads — kept in sync by `AgentRuns`
  via `Onboardings.update_status/2`, never written directly from an `AgentRuns` query
- `AgentRun.status` (`Ecto.Enum`: `:processing, :needs_review, :approved, :rejected`) is
  that specific run's outcome — a re-run gets a new row, not an overwritten one
- **Tax ID is PII** — encrypt at rest (`Cloak.Ecto` custom type, `VendorOnboarding.Encrypted.Binary`),
  never a plaintext column. Lives on `AgentRun`, not `Onboarding`. Hard requirement from
  CONTEXT.md, not a nice-to-have.
- Payment Terms / Liability Clauses are free text (`:string`) — not strictly typed,
  validated via the Python-side LLM-judge, not an Ecto changeset rule
- Idempotency key: unique index on `onboardings`, `hash of raw payload`, checked in
  `Onboardings.Repository` before insert

---

## 4. error handling

- All context functions return `{:ok, result} | {:error, reason}`
- Reason is a changeset, an atom (`:not_found`, `:duplicate`, `:not_awaiting_review`), or
  a string (external service error)
- Use `with` for multi-step actions — fail fast, one error path
- Bang functions only in LiveView assigns
- Never rescue in context functions for expected failures; the `AgentService` HTTP client
  boundary is the one place `rescue`/timeout handling belongs, since it's a real external call

---

## 5. performance + query patterns

- Filter/sort in SQL, not `Enum` after the fact
- Index `onboardings.idempotency_key` (unique), `onboardings.status`,
  `agent_runs.vendor_onboarding_id`, `agent_runs.thread_id`, `agent_runs.status`
- `AgentRuns.latest_by_onboarding_ids/1` batches the dashboard's "latest run per
  onboarding" lookup in one query (Postgres `DISTINCT ON`-style, via `distinct` +
  matching `order_by`) — never N+1 per row
- Order-by ties: `agent_runs` uses `timestamps(type: :utc_datetime)` (second
  granularity), so "latest run" queries order by `[desc: :inserted_at, desc: :id]`,
  not `inserted_at` alone — two runs created in the same second would otherwise
  tie non-deterministically
- Paginate the LiveView dashboard list — never fetch unbounded onboarding rows

---

## 6. LiveView structure

- One LiveView for the dashboard (list + status, calls `Onboardings.list_onboardings_with_latest_run/1`),
  one for the review detail (paused case, side-by-side contract/W-9 diff, approve action —
  assigns both `@onboarding` (`Onboardings.get_onboarding!/1`) and `@agent_run`
  (`AgentRuns.get_latest_for_onboarding/1`), calls each context directly rather than
  through an intermediary)
- `handle_event` callbacks ≤ 5 lines — delegate to `Onboardings.*` / `AgentRuns.*` immediately
- PubSub topic per onboarding row (or a single `"vendor_onboarding"` topic broadcasting
  `{:status_updated, id}`) — dashboard subscribes and reloads the affected row, not the whole list

---

## 7. elixir fundamentals

Same as `better_me`/`dentos`: immutability + pipelines, pattern matching over conditionals,
let it crash (except at the `AgentService` HTTP boundary), tagged tuples & `with`, `Enum`/`Stream`
over `for`, `snake_case`/`PascalCase` naming, `?`/`!` suffix conventions.

---

## summary — the checklist

- [ ] Schema is private to its context's `schema/` directory
- [ ] No context aliases or queries the other context's `Schema`/`Repository` — only its public API
- [ ] All functions return `{:ok, _} | {:error, _}`
- [ ] No bare `Repo.*` calls outside a context's own `repository.ex`
- [ ] No bare HTTP calls to the Python service outside `agent_runs/agent_service.ex`
- [ ] Tax ID stored via an encrypted Ecto type, never plaintext
- [ ] Idempotency key checked before any row is created
- [ ] `thread_id` is written to the run row on every pause callback — this is what makes resume possible
- [ ] `Onboarding.status` stays in sync with the latest `AgentRun.status` via `Onboardings.update_status/2`
- [ ] LiveView `handle_event` delegates to `Onboardings`/`AgentRuns` within 5 lines
- [ ] Queries filter/sort in SQL, not `Enum`
- [ ] Batched lookups (not N+1) for any list that needs data from both contexts
- [ ] At least one test for the happy path and one for the duplicate/idempotency case
