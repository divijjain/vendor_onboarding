# vendor_onboarding — Elixir design principles

Ported from `better_me`/`dentos`. Applies without change except where
this project's shape differs (single primary domain, external Python
service instead of multiple LiveView-only domains).

Reference this before writing any new module.

---

## 1. one primary domain, three internal layers

Unlike `better_me` (many small domains), this app has one primary domain:
`VendorOnboarding`. Depth comes from layering, not domain count.

```
public API  →  vendor_onboarding.ex              defdelegate only, no logic
repo layer  →  vendor_onboarding/repository.ex    all Repo.* calls, query composition
action layer → vendor_onboarding/actions/*.ex     coordination, side effects, multi-step ops
pure logic  →  vendor_onboarding/idempotency.ex    no DB, no side effects (e.g. hash computation)
schemas     →  vendor_onboarding/schema/*.ex       Ecto schemas and changesets
```

### rules
- `vendor_onboarding.ex` contains only `defdelegate` — nothing else, ever
- `repository.ex` is the only file that calls `Repo.*` directly
- Action modules call `Repository.*`, `AgentService.*` (the Req-based HTTP client to
  the Python service), and other actions — never `Repo.*` directly
- Action modules are private — never called from outside the context
- Pure logic modules (idempotency hashing, payload parsing) have no DB or
  side-effect dependencies
- Keep action modules focused: if it grows beyond ~30 lines, split it

### structure
```
lib/vendor_onboarding/
  schema/
    vendor_onboarding.ex        # Ecto schema + changesets
  actions/
    ingest_webhook.ex           # idempotency check, storage, row creation, job enqueue
    trigger_agent_run.ex        # called from Oban job — calls AgentService, handles callback shape
    handle_agent_callback.ex    # writes status/thread_id back, broadcasts PubSub
    resume_review.ex            # human approval -> AgentService.resume/1
  agent_service.ex              # Req-based HTTP client to the Python/FastAPI service
  repository.ex                 # all Repo calls
  idempotency.ex                # pure — hash of raw payload
vendor_onboarding.ex            # public API — defdelegate only
```

### the strict boundary rule
- **`repository.ex` only touches `Repo.*`** — no coordination, no HTTP calls, no calling other contexts
- **`actions/*.ex` never calls `Repo.*` directly** — actions call `Repository.*` and `AgentService.*`
- **Anything that bridges a repo call and an HTTP call to the Python service belongs in an action** —
  e.g. `TriggerAgentRun` reads the row via `Repository.get`, then calls `AgentService.trigger/1`,
  then writes the result back via `Repository.update_status/2`. That sequencing is coordination.

---

## 2. context design

- `vendor_onboarding.ex` contains only `defdelegate` — no `import`, no `alias`, no logic
- Repository and action functions scope to what's available for this app: there's no
  multi-tenant `user_id` here (vendor onboarding is an internal back-office tool), but
  every query still filters by ID/idempotency key explicitly — never fetch unbounded lists
- All context functions return `{:ok, result} | {:error, reason}`

### function naming conventions
```elixir
ingest_webhook(raw_payload)              # {:ok, onboarding} | {:error, :duplicate | changeset}
get_onboarding(id)                       # {:ok, onboarding} | {:error, :not_found}
get_onboarding!(id)                      # raises — only in LiveView assigns
list_onboardings(opts \\ [])             # returns list, filter/sort in SQL
trigger_agent_run(onboarding_id)         # delegates to TriggerAgentRun action
handle_agent_callback(payload)           # delegates to HandleAgentCallback action
resume_review(onboarding_id, decision)   # delegates to ResumeReview action
```

---

## 3. schema + changeset patterns

- Plain integer primary keys (Ecto default) — no `binary_id`
- Use `Ecto.Enum` for `status` (`:received, :processing, :needs_review, :approved, :rejected`)
- **Tax ID is PII** — encrypt at rest (e.g. `Cloak.Ecto` custom type), never a plaintext column.
  This is a hard requirement from CONTEXT.md, not a nice-to-have.
- Payment Terms / Liability Clauses are free text (`:string`/`:text`) — not strictly typed,
  validated via the Python-side LLM-judge, not an Ecto changeset rule
- Idempotency key: unique index, `hash of raw payload`, checked in `repository.ex` before insert

---

## 4. error handling

- All context functions return `{:ok, result} | {:error, reason}`
- Reason is a changeset, an atom (`:not_found`, `:duplicate`), or a string (external service error)
- Use `with` for multi-step actions — fail fast, one error path
- Bang functions only in LiveView assigns
- Never rescue in context functions for expected failures; the `AgentService` HTTP client
  boundary is the one place `rescue`/timeout handling belongs, since it's a real external call

---

## 5. performance + query patterns

- Filter/sort in SQL, not `Enum` after the fact
- Index `idempotency_key` (unique), `status`, `thread_id`
- Paginate the LiveView dashboard list — never fetch unbounded onboarding rows

---

## 6. LiveView structure

- One LiveView for the dashboard (list + status), one for the review detail (paused case,
  side-by-side contract/W-9 diff, approve action)
- `handle_event` callbacks ≤ 5 lines — delegate to `VendorOnboarding.*` immediately
- PubSub topic per onboarding row (or a single `"vendor_onboarding"` topic broadcasting
  `{:status_updated, id}`) — dashboard subscribes and reloads the affected row, not the whole list

---

## 7. elixir fundamentals

Same as `better_me`/`dentos`: immutability + pipelines, pattern matching over conditionals,
let it crash (except at the `AgentService` HTTP boundary), tagged tuples & `with`, `Enum`/`Stream`
over `for`, `snake_case`/`PascalCase` naming, `?`/`!` suffix conventions.

---

## summary — the checklist

- [ ] Schema is private to `vendor_onboarding/schema/`
- [ ] All functions return `{:ok, _} | {:error, _}`
- [ ] No bare `Repo.*` calls outside `repository.ex`
- [ ] No bare HTTP calls to the Python service outside `agent_service.ex`
- [ ] Tax ID stored via an encrypted Ecto type, never plaintext
- [ ] Idempotency key checked before any row is created
- [ ] `thread_id` is written to the row on every pause callback — this is what makes resume possible
- [ ] LiveView `handle_event` delegates to `VendorOnboarding` within 5 lines
- [ ] Queries filter/sort in SQL, not `Enum`
- [ ] At least one test for the happy path and one for the duplicate/idempotency case
