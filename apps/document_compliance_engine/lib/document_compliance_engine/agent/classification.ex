defmodule DocumentComplianceEngine.Agent.Classification do
  @moduledoc """
  Agent 0: decides *which* document type a job is, when the caller didn't
  say. Until this existed, `document_type_slug` had to arrive in the
  webhook payload — the caller was required to already know which template
  applied, which is the thing a document-understanding system is supposed
  to work out for itself.

  This is deliberately a differently-shaped pipeline stage from the two
  that came before it: no `extraction_schema` drives it, its output is a
  single slug rather than a map of fields, and its candidates are *rows*
  (`document_types`) rather than config attached to one known row. It
  reads the same `description` and `shape_signals` config the rest of the
  pipeline uses, from the other direction.

  **Staged, like `Checks.entity_match/2` before it.** A free, deterministic
  pre-filter runs first: each candidate's own `shape_signals` keywords are
  counted against the document text, and when *exactly one* candidate
  clears its configured threshold, that's the answer and no LLM call
  happens at all. Zero or several survivors is genuinely ambiguous, and
  only then does an LLM see the candidate descriptions. Skipping the call
  is a real saving, but a wrong auto-classification is worse than a call,
  so the deterministic path only fires on an unambiguous majority of one.

  **Low confidence is not an error, and not a silent guess.** The result
  carries `confident?`, which is false when the winner scored below
  `confidence_threshold/0` or when no candidate could be picked at all.
  The caller (`DocumentReactor`'s `:classify` step) turns that into an
  ordinary failed check, which routes the run to human review through the
  exact halt/`:gate`/`:finalize` machinery every other failed check
  already uses — rather than a second, parallel pause mechanism that
  would need its own checkpoint, its own resume path and its own reviewer
  vocabulary. The reviewer sees the proposed type, its confidence, and
  what the pipeline extracted *under that assumption*, which is the
  evidence needed to accept or reject it.

  A slug the model invents that isn't in the candidate list is treated as
  "could not classify", never as a type — the registry is the only
  authority on what document types exist.
  """

  require Logger

  alias DocumentComplianceEngine.Agent.Extraction

  # Bounds the prompt: a classification decision is made from a document's
  # opening far more than its tail (letterheads, titles and totals live at
  # the top), and a whole multi-page contract would otherwise dominate the
  # cost of a step whose entire output is one slug.
  @text_limit 3_000

  # Calibrated against this project's own eval corpus rather than guessed,
  # the same way the entity-match thresholds in `Checks` were. `mix
  # eval.classify` runs all 79 fixtures with their declared type withheld,
  # against all six seeded types: every fixture that belongs to a type was
  # placed correctly with confidence 0.80-1.00 (n=76, avg 0.98), and every
  # fixture that belongs to none of them (the résumé/cover-letter
  # wrong-type bucket) came back at 0.00-0.20 (n=3). This threshold sits
  # in the gap between those two populations.
  #
  # Deliberately set nearer the *correct* side of that gap (0.75, not the
  # 0.50 midpoint) rather than tuned to maximise auto-processing: a
  # borderline case sent to a human costs review time, while a confidently
  # wrong document type extracts and validates the wrong fields entirely
  # and could auto-approve on them.
  #
  # **The margin under it has since gone to zero, and that is recorded
  # rather than tuned away.** Growing the corpus to 108 fixtures and the
  # registry to nine candidate types dropped the lowest correct placement
  # from 0.80 to exactly 0.75 — `scanned-malformed-01`, the deliberately
  # blurred scan. It still passed, and in practice that document halts for
  # extraction reasons regardless, so nothing was misrouted. But the
  # honest reading is that this number's evidence got *weaker* as the
  # corpus grew, not stronger, and the case that would actually move it is
  # a **clean, unambiguous** document scoring at or below 0.75. Zero
  # misclassifications in 108 means the risk this threshold guards against
  # has still never been observed at all.
  @confidence_threshold 0.75

  @type result :: %{
          slug: String.t() | nil,
          confidence: float(),
          source: :caller | :shape_signals | :llm | :none,
          reasoning: String.t() | nil,
          confident?: boolean()
        }

  @typedoc """
  A candidate document type, as plain string-keyed config rather than a
  `DocumentType` struct: these are stored verbatim in the checkpoint's
  jsonb `inputs` and come back string-keyed on resume, the same way
  `validation_rules` and `shape_signals` always have.
  """
  @type candidate :: %{String.t() => term()}

  @doc """
  Presents `document_types` rows as the string-keyed candidate config the
  reactor takes as input. One place rather than two, because these maps
  are also what the checkpoint stores: `Agent.Run` and the eval harness
  building them differently is how a resumed run would end up seeing
  different candidates than the run that halted.
  """
  @spec candidates([struct()]) :: [candidate()]
  def candidates(document_types) do
    Enum.map(document_types, fn document_type ->
      %{
        "slug" => document_type.slug,
        "name" => document_type.name,
        "description" => document_type.description,
        "extraction_schema" => document_type.extraction_schema,
        "validation_rules" => document_type.validation_rules,
        "shape_signals" => document_type.shape_signals
      }
    end)
  end

  @doc "The confidence a classification must reach to proceed without a human."
  @spec confidence_threshold() :: float()
  def confidence_threshold, do: @confidence_threshold

  @doc """
  Classifies `documents` (role => text, as uploaded) against `candidates`.

  A caller-supplied `slug` short-circuits the whole thing: an explicit
  declaration from the integrator beats an inference, and re-deriving it
  would be spending money to second-guess someone who already knows. It's
  still checked against the registry, so a typo'd slug is a loud
  `:unknown_document_type` rather than a silent misclassification.
  """
  @spec classify(%{String.t() => String.t()}, [candidate()], String.t() | nil) ::
          {:ok, result()} | {:error, term()}
  def classify(documents, candidates, caller_slug \\ nil)

  def classify(_documents, candidates, slug) when is_binary(slug) do
    if known_slug?(candidates, slug) do
      {:ok, resolved(slug, 1.0, :caller, "Document type supplied by the caller")}
    else
      {:error, {:unknown_document_type, slug}}
    end
  end

  def classify(documents, candidates, nil) do
    text = combined_text(documents)

    case shape_signal_match(text, candidates) do
      {:ok, slug} ->
        {:ok,
         resolved(slug, 1.0, :shape_signals, "Only #{slug} matched its own document signals")}

      :ambiguous ->
        llm_classify(text, candidates)
    end
  end

  defp resolved(slug, confidence, source, reasoning) do
    %{
      slug: slug,
      confidence: confidence,
      source: source,
      reasoning: reasoning,
      confident?: confidence >= @confidence_threshold
    }
  end

  @doc """
  The free pre-filter: `{:ok, slug}` only when exactly one candidate has a
  role whose `shape_signals` gate the text clears. Reuses
  `Extraction.shape_matches?/2` — the same function that decides whether a
  role is worth extracting — so a document type's keywords mean the same
  thing in both directions rather than being configured twice.

  A candidate that configures no `shape_signals` at all can never win here
  (it would match everything), and falls through to the LLM.
  """
  @spec shape_signal_match(String.t(), [candidate()]) :: {:ok, String.t()} | :ambiguous
  def shape_signal_match(text, candidates) do
    case Enum.filter(candidates, &shape_signals_match?(text, &1)) do
      [candidate] -> {:ok, candidate["slug"]}
      _none_or_several -> :ambiguous
    end
  end

  defp shape_signals_match?(text, candidate) do
    case candidate["shape_signals"] do
      shape_signals when is_map(shape_signals) and map_size(shape_signals) > 0 ->
        Enum.any?(shape_signals, fn {_role, shape} -> Extraction.shape_matches?(text, shape) end)

      _unconfigured ->
        false
    end
  end

  defp known_slug?(candidates, slug), do: Enum.any?(candidates, &(&1["slug"] == slug))

  defp combined_text(documents) do
    documents
    |> Enum.sort_by(fn {role, _text} -> role end)
    |> Enum.map_join("\n\n", fn {role, text} ->
      "--- #{role} ---\n#{String.slice(text, 0, @text_limit)}"
    end)
  end

  defp llm_classify(text, candidates) do
    case Application.get_env(:document_compliance_engine, :agent_classify) do
      nil -> complete(text, candidates)
      fun -> fun.(text, candidates) |> interpret(candidates)
    end
  end

  defp complete(text, candidates) do
    case Instructor.chat_completion(
           model: "gpt-4o-mini",
           response_model: %{slug: :string, confidence: :float, reasoning: :string},
           max_retries: 1,
           messages: [%{role: "user", content: prompt(text, candidates)}]
         ) do
      {:ok, raw} -> interpret({:ok, raw}, candidates)
      error -> error
    end
  end

  # An invented slug is not a document type. Reported as "could not
  # classify" with the model's own reasoning kept for the reviewer, rather
  # than coerced onto the nearest real candidate.
  defp interpret({:ok, %{slug: slug} = raw}, candidates) do
    if known_slug?(candidates, slug) do
      {:ok, resolved(slug, raw.confidence || 0.0, :llm, Map.get(raw, :reasoning))}
    else
      Logger.info("classifier returned a slug outside the registry: #{inspect(slug)}")

      {:ok,
       %{
         slug: nil,
         confidence: 0.0,
         source: :none,
         reasoning: Map.get(raw, :reasoning) || "No candidate document type matched",
         confident?: false
       }}
    end
  end

  defp interpret(other, _candidates), do: other

  @doc """
  The classification prompt. Public for the same reason `Extraction.prompt/2`
  is: the candidate descriptions are the entire input to this decision, so
  what they look like assembled is worth asserting on directly.
  """
  @spec prompt(String.t(), [candidate()]) :: String.t()
  def prompt(text, candidates) do
    """
    Decide which one of the following document types this document is. Each \
    candidate is given as a slug and a description of what that kind of \
    document is.

    #{Enum.map_join(candidates, "\n", &candidate_line/1)}

    Answer with:
    - slug: the slug of the single best-matching candidate, exactly as written \
    above. If the document is not any of them, answer with the slug "unknown".
    - confidence: 0.0 to 1.0, how sure you are. Be honest: a document that \
    could plausibly be two of these candidates is not a confident answer, and \
    neither is one that is none of them.
    - reasoning: one sentence naming the evidence in the document that decided it.

    Document:
    #{text}
    """
  end

  defp candidate_line(candidate) do
    slug = candidate["slug"]
    "- #{slug}: #{candidate["description"] || candidate["name"] || slug}"
  end
end
