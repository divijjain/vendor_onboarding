# Benchmark: extraction & compliance-decision accuracy

This is the full methodology and results behind the "0% hallucination rate on extracted
entities" claim in the [README](README.md#evaluation) — pulled into its own document because a
claim like that is only worth as much as the benchmark backing it, and a benchmark buried in a
paragraph is hard to audit. The structure below is modeled deliberately on how
[Nutrient documents its own benchmarks](https://www.nutrient.io/blog/pdf-extraction-benchmark-opendataloader-bench/)
(opendataloader-bench, the PDF SDK benchmark): state what's pinned, run the full corpus every
time, report the miss you didn't want, and make it reproducible by someone who isn't you.

## What's pinned

| Parameter | Value |
|---|---|
| Agent model (extraction, entity-match, explanation drafting) | `gpt-4o-mini` |
| Judge model (scoring the agent's output) | `claude-sonnet-5`, a different provider than the agent — avoids self-grading inflation |
| Tool servers | Both mock MCP servers (`tax_api`, `sanctions_db`) running live, real HTTP calls — not stubbed for this run |
| Production check reuse | The eval's groundedness check (`Checks.grounded_extraction_checks/3`) is the *exact same function* the live pipeline calls to gate a real run, not a second eval-only reimplementation that could quietly drift from what production actually does |
| Corpus | Fixed, versioned, committed to this repo (`Agent.Evals.Fixtures`) — same set every run, not resampled |
| Fixture selection | No cherry-picking: the harness runs every fixture in the corpus, every time, and reports every bucket, including the ones that don't flatter the number |

## Two-tier scoring, not LLM-as-judge for everything

Grading your own extraction with the same model that did the extracting is close to
worthless — so only the parts of this system that are genuinely a judgment call go through an
LLM judge. Everything with an objective right answer is checked deterministically:

1. **Deterministic checks** (no LLM, free, and the same code path that gates the real pipeline):
   does every extracted field appear verbatim in its own source document
   (`grounded_extraction_checks/3`, any document type)? Does the Tax ID match the W-9 text
   exactly? Does the output conform to the document type's `extraction_schema`? These produce
   the hallucination-rate number — it's a string-containment check, not a model's opinion.
2. **LLM-as-judge checks** (for what's genuinely ambiguous): does an entity-name pairing still
   hold under formatting differences ("J. Smith" vs "John Smith")? Is a drafted explanation for
   a halted run actually grounded in the real findings, or is it padding? Both are scored by
   `claude-sonnet-5` grading `gpt-4o-mini`'s work.

## Corpus

69 fixtures across two structurally different document types — grown specifically so the
thinnest buckets aren't one failure away from a meaningless swing (see below).

### `vendor_contract_w9` — 55 fixtures

| Bucket | Count | Tests |
|---|---|---|
| Clean, should auto-approve | 20 | happy path |
| Genuine name/entity mismatch | 15 | true-positive flagging |
| Subtle formatting difference, not a real mismatch | 12 | false-positive rate — the bucket that makes a near-100% claim credible instead of cherry-picked |
| Missing/malformed fields | 8 | graceful degradation |

Grown from an original 20 (10/5/3/2): at that size, two buckets were thin enough that a single
failure swung that bucket's reported accuracy by 33–50 points, and the headline number carried
too wide a confidence interval to distinguish a ~95%-accurate system from a 100%-accurate one.
Growth was weighted toward the buckets that needed it (formatting 3→12, malformed 2→8), not
scaled uniformly.

### `invoice` — 14 fixtures

| Bucket | Count | Tests |
|---|---|---|
| Clean, should auto-approve | 6 | happy path |
| Sanctions hit | 2 | true-positive flagging — the exact two names the mock sanctions server's watchlist contains, not invented values that would pass or fail by coincidence |
| Malformed (vendor name present, other fields genuinely absent) | 3 | `extraction_completeness` catching a mostly-empty extraction |
| Wrong document type (résumé/cover-letter text, not an invoice) | 3 | the shape gate rejecting it before any extraction call — zero LLM cost |

The wrong-document-type bucket isn't hypothetical — an uploaded résumé was once extracted into a
fully fabricated invoice (vendor name, amount, and due date all invented from a document that
mentioned none of them) before the shape gate existed. That real incident is now a permanent
regression test, not a story that only lives in a commit message.

69 fixtures is still not benchmark-scale — a couple of buckets are small enough that one failure
is visible in the headline number. It's past the point where the numbers were mostly noise, not
past the point where they're statistically strong.

## Results — run for real

`mix eval.run`, both API keys live, both mock MCP servers running. Every number below is an
actual model/tool-server response, not a fake standing in for one.

| Bucket | Decision accuracy |
|---|---|
| `vendor_contract_w9` / clean | 20/20 |
| `vendor_contract_w9` / mismatch | 15/15 |
| `vendor_contract_w9` / formatting | **11/12** |
| `vendor_contract_w9` / malformed | 8/8 |
| `invoice` / clean | 6/6 |
| `invoice` / sanctions hit | 2/2 |
| `invoice` / malformed | 3/3 |
| `invoice` / wrong document type | 3/3 |

**66/69 buckets aside, the headline hallucination-rate number** — the deterministic
groundedness check across every extracted field, every fixture, both document types — is **0%**:
no field the pipeline reported as extracted failed to appear verbatim in its own source
document, across all 69 fixtures.

LLM-judge tier (cross-provider, `claude-sonnet-5` scoring `gpt-4o-mini`'s calls):

| Judge metric | Score | n |
|---|---|---|
| Entity-match correctness | **0.98** | 47 — every `vendor_contract_w9` fixture with a known expected match/mismatch |
| Explanation groundedness | **1.00** | 32 — every fixture across both document types that actually halted with an explanation |

### The one miss, reported honestly

`formatting-07` ("The Wilson Group" vs "Wilson Group LLC") landed in the entity-matcher's
ambiguous band and `gpt-4o-mini`'s judgment call this run said "different entities." That's a
genuine, debatable model call, not a bug in this codebase — a reasonable person could argue it
either way. It's reported here instead of re-run until it disappeared, because an eval that
always comes back a suspiciously clean 100% is worth trusting less than one that shows its one
real disagreement. It's also most of the gap between the entity-match score above and a perfect
1.00.

A second bug the eval process itself surfaced, not swept under: an earlier run once reported
groundedness as `n=4` instead of the expected `n=5` — `judge_scores/1` used to silently drop a
failed judge call from the average instead of counting it as a failure, so the gap wasn't
visible until the harness was made to surface failures explicitly. The dropped call turned out
to be a real parsing bug (Claude's extended-thinking responses put a `type: "thinking"` block
ahead of `type: "text"`, and the judge's response parser assumed the first block was always the
answer) — fixed to search for the actual text block instead of assuming its position. An eval
harness that can silently hide its own failures is exactly the failure mode this whole project
exists to catch on the agent side, so that bug got the same scrutiny a pipeline bug would.

## Reproduce it yourself

The corpus, scoring code, and this exact methodology are committed to this repository, not held
back as a private report:

```
cd apps/document_compliance_engine
mix eval.run
```

Requires `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` and both mock MCP servers running
(`apps/tax_api`, `apps/sanctions_db`) — see the [README](README.md#local-development) for setup.
No held-back fixtures, no hidden config: `lib/document_compliance_engine/agent/evals/fixtures.ex`
is the entire corpus.

## What this benchmark doesn't claim

- **Not benchmark-scale.** 69 fixtures is enough to stop the numbers from being mostly noise, not
  enough to report a tight confidence interval. A couple of buckets are still one failure away
  from a visible swing.
- **Authored, not collected.** The corpus is hand-constructed to exercise specific failure
  modes (including one real production incident), not sampled from real production traffic —
  it proves the checks catch what they're designed to catch, not that it matches the true
  distribution of documents this system would see in the wild.
- **A point-in-time snapshot.** LLM APIs drift; this run reflects `gpt-4o-mini`/`claude-sonnet-5`
  behavior on the date it was run, not a guarantee that hasn't moved since. Unlike a benchmark
  re-run on every release, this one is run on demand — `mix eval.run` is cheap enough (real API
  calls, not free) that it isn't wired into CI yet.
