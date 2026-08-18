defmodule DocumentComplianceEngine.Agent.Checks do
  @moduledoc """
  Agent 2: interprets a document type's `validation_rules` against the
  extracted data. Two rule types:

    - `entity_match` — an LLM judgment comparing two named fields (e.g.
      the contract's and W-9's company names)
    - `mcp_tool` — calls one of the two known MCP tools
      (`validate_tax_id`/`screen_vendor`) against one named field

  The two tools themselves stay a fixed, known pair — only which
  document/field feeds them varies by document type, so their
  human-readable failure messages stay hardcoded per tool rather than
  generated generically.

  `validate_all/5` also runs three automatic checks on every extracted
  field, unconditionally — none is one of `validation_rules`, so none
  can be configured away per document type:

    - `grounded_extraction_checks/3` — every non-blank extracted string
      must appear in the source text it came from. `Extraction` prompts
      the model to pull fields "verbatim as written"; a field that
      doesn't appear in the source either broke that instruction or was
      invented outright. When the document type configures
      `shape_signals` for a role, this also requires the match to fall
      near one of that role's configured keywords — plain substring
      presence isn't enough on its own, since a long, multi-topic
      document (a résumé, say) can contain a real dollar figure or date
      that has nothing to do with the field it got mapped to. (Distinct
      from `Evals.Judge.groundedness/2`, which scores whether a *drafted
      explanation* is grounded in validation findings — this checks
      whether *extracted field values* are grounded in the source
      document.)
    - `extraction_completeness_checks/1` — a role where most fields came
      back `nil` (via `Extraction`'s `"NOT_PRESENT"` sentinel, or a
      `shape_signals` skip) is treated as a real signal that the document
      isn't actually that role's type, not noise to shrug off.
    - `low_confidence_checks/2` — a field the model itself reported low
      confidence on (see `Extraction`'s moduledoc for where that number
      comes from) gets flagged too. A *complementary* signal to
      `grounded_extraction_checks/3`, not a replacement for it — a
      model's self-reported confidence is exactly the kind of claim this
      project is generally skeptical of taking at face value on its own.
  """

  alias DocumentComplianceEngine.Agent.McpClient
  alias DocumentComplianceEngine.Agent.Schemas.EntityMatchResult
  alias DocumentComplianceEngine.Agent.ValidationResult

  @entity_match_prompt """
  Do these two names refer to the same legal entity? Minor formatting \
  differences (abbreviations, punctuation, "Corp" vs "Corporation") are still a \
  match; a genuinely different vendor name is not.

  Name A: %{name_a}
  Name B: %{name_b}
  """

  # Calibrated against this project's own eval fixtures (see
  # test/document_compliance_engine/agent/checks_test.exs), not guessed: on
  # the "formatting" bucket (same entity, cosmetic difference) normalized
  # Jaro distance ranges 0.82-0.854; on the "mismatch" bucket (genuinely
  # different entities) it ranges 0.475-0.65. There's a real gap between
  # those two ranges, with margin on both sides, which is what these
  # thresholds sit inside — the ambiguous band between them always goes to
  # the LLM. Skipping the LLM call is a real cost/latency win (see
  # CONTEXT.md's dated entry), but a false auto-match/auto-mismatch on a
  # compliance decision is worse than an extra call, so both thresholds are
  # deliberately conservative rather than tuned to maximize skips.
  @clear_match_threshold 0.95
  @clear_mismatch_threshold 0.70

  @explanation_prompt """
  Draft a brief, concrete explanation of the discrepancy found while validating \
  this document job, grounded only in the facts below. Do not invent details.

  %{findings}
  """

  @spec validate_all(%{String.t() => map()}, %{String.t() => String.t()}, [map()], map(), map()) ::
          {:ok, ValidationResult.t()} | {:error, term()}
  def validate_all(
        extracted,
        documents,
        validation_rules,
        shape_signals \\ %{},
        extraction_metadata \\ %{}
      ) do
    automatic =
      grounded_extraction_checks(extracted, documents, shape_signals) ++
        extraction_completeness_checks(extracted) ++
        low_confidence_checks(extracted, extraction_metadata)

    validation_rules
    |> Enum.reduce_while({:ok, automatic}, fn rule, {:ok, acc} ->
      case run_rule(rule, extracted) do
        {:ok, check} -> {:cont, {:ok, [check | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, checks} -> {:ok, %ValidationResult{checks: Enum.reverse(checks)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # How much surrounding text (bytes, each side) counts as "near" a
  # keyword when `shape_signals` are configured for a role — see
  # `grounded_extraction_checks/3`.
  @context_window 100

  @doc """
  Deterministic (no LLM) check that every non-blank extracted string field
  actually appears in the source text it was extracted from, case- and
  whitespace-insensitively. Runs against every field in `extracted`
  regardless of whether any configured `validation_rules` entry happens to
  reference it — the whole point is to catch a fabricated field a document
  type's config didn't think to check.

  When `shape_signals` configures keywords for a role, plain substring
  presence isn't enough — the match must also fall within
  #{@context_window} bytes of one of those keywords somewhere in the
  source. A document with no real content for a role can still contain a
  real, verbatim number or date that means something else entirely (see
  CONTEXT.md's dated entry on the résumé-as-invoice case this closes);
  requiring nearby field-relevant vocabulary is a cheap way to tell "this
  value is really here for this reason" from "this value happens to be
  somewhere in a long, unrelated document."
  """
  @spec grounded_extraction_checks(%{String.t() => map()}, %{String.t() => String.t()}, map()) ::
          [ValidationResult.check()]
  def grounded_extraction_checks(extracted, documents, shape_signals \\ %{}) do
    for {role, fields} <- extracted,
        {field, value} <- fields,
        is_binary(value),
        normalized_value = normalize_text(value),
        normalized_value != "",
        source = normalize_text(Map.get(documents, role, "")),
        not grounded?(normalized_value, source, shape_signals[role]) do
      %{
        rule: %{"type" => "grounded_extraction", "field" => %{"role" => role, "name" => field}},
        passed: false,
        detail:
          "Extracted #{field} for #{role} (#{inspect(value)}) does not appear in the source document — possible hallucination."
      }
    end
  end

  defp grounded?(value, source, shape) do
    String.contains?(source, value) and near_keywords?(value, source, shape)
  end

  defp near_keywords?(_value, _source, nil), do: true
  defp near_keywords?(_value, _source, shape) when map_size(shape) == 0, do: true

  defp near_keywords?(value, source, %{"keywords" => keywords}) do
    normalized_keywords = Enum.map(keywords, &normalize_text/1)

    source
    |> :binary.matches(value)
    |> Enum.any?(fn {start, len} ->
      window_start = max(0, start - @context_window)
      window_end = min(byte_size(source), start + len + @context_window)
      window = :binary.part(source, window_start, window_end - window_start)

      Enum.any?(normalized_keywords, &String.contains?(window, &1))
    end)
  end

  @doc """
  Deterministic (no LLM) check that a role's extraction didn't come back
  mostly empty. `Extraction` can now honestly answer "not present" per
  field (a `"NOT_PRESENT"` sentinel, or a `shape_signals` skip — see its
  moduledoc) instead of being forced to invent something, which means a
  role where most fields came back `nil` is real evidence the document
  isn't actually that role's type, not just sparse data.
  """
  @spec extraction_completeness_checks(%{String.t() => map()}) :: [ValidationResult.check()]
  def extraction_completeness_checks(extracted) do
    for {role, fields} <- extracted,
        map_size(fields) > 0,
        missing = Enum.count(fields, fn {_field, value} -> blank?(value) end),
        missing / map_size(fields) > 0.5 do
      %{
        rule: %{"type" => "extraction_completeness", "role" => role},
        passed: false,
        detail:
          "#{missing}/#{map_size(fields)} fields for #{role} came back empty — this document may not actually match the #{role} document type."
      }
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  # Not empirically calibrated the way the entity-match thresholds above
  # are (no eval data yet on how well-calibrated GPT-4o-mini's
  # self-reported confidence actually is) — a conservative default
  # pending real data, not a tuned number.
  @low_confidence_threshold 0.7

  @doc """
  Deterministic (no LLM call of its own) check on the model's own
  self-reported confidence per field — see `Extraction`'s moduledoc for
  where the number comes from: a real LLM call, a synthesized `1.0` for a
  regex-resolved field, or `nil` for a shape-gate-skipped one. Only a
  genuinely reported numeric confidence below the threshold is flagged;
  `nil` (not attempted, or a fake that didn't supply metadata) is left
  alone — `extraction_completeness_checks/1` already covers "not
  attempted."
  """
  @spec low_confidence_checks(%{String.t() => map()}, map()) :: [ValidationResult.check()]
  def low_confidence_checks(extracted, extraction_metadata) do
    for {role, fields} <- extracted,
        {field, value} <- fields,
        is_binary(value),
        confidence = get_in(extraction_metadata, [role, field, :confidence]),
        is_number(confidence),
        confidence < @low_confidence_threshold do
      %{
        rule: %{"type" => "low_confidence", "field" => %{"role" => role, "name" => field}},
        passed: false,
        detail:
          "Extracted #{field} for #{role} has low model-reported confidence (#{Float.round(confidence * 1.0, 2)}) — flagged for review."
      }
    end
  end

  defp normalize_text(text) do
    text |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  # Every rule below guards its field(s) as blank *before* reaching an LLM
  # or MCP call — extraction can now honestly return `nil` (see
  # `extraction_completeness_checks/1`'s moduledoc), and the two MCP mock
  # servers declare their string arguments `required`, so a `nil` sent
  # over the wire would error the whole run to `:failed` rather than
  # cleanly halting to `:needs_review`. A blank field is itself a valid,
  # synthesized check failure — not something that should ever reach an
  # external call.
  defp run_rule(%{"type" => "entity_match", "fields" => [a, b]} = rule, extracted) do
    value_a = field_value(extracted, a)
    value_b = field_value(extracted, b)

    if blank?(value_a) or blank?(value_b) do
      {:ok,
       %{
         rule: rule,
         passed: false,
         detail: "Cannot compare entity names — one or both fields were not extracted."
       }}
    else
      with {:ok, result} <- entity_match(value_a, value_b) do
        {:ok,
         %{
           rule: rule,
           passed: result.match,
           detail: unless(result.match, do: "Entity name mismatch: #{result.explanation}")
         }}
      end
    end
  end

  defp run_rule(
         %{"type" => "mcp_tool", "tool" => "validate_tax_id", "field" => field} = rule,
         extracted
       ) do
    value = field_value(extracted, field)

    if blank?(value) do
      {:ok,
       %{
         rule: rule,
         passed: false,
         detail: "Cannot validate Tax ID — the field was not extracted."
       }}
    else
      with {:ok, %{valid: valid}} <- McpClient.validate_tax_id(value) do
        {:ok,
         %{
           rule: rule,
           passed: valid,
           detail: unless(valid, do: "Tax ID failed validation against the mock tax registry.")
         }}
      end
    end
  end

  defp run_rule(
         %{"type" => "mcp_tool", "tool" => "screen_vendor", "field" => field} = rule,
         extracted
       ) do
    value = field_value(extracted, field)

    if blank?(value) do
      {:ok,
       %{rule: rule, passed: false, detail: "Cannot screen vendor — the field was not extracted."}}
    else
      with {:ok, %{flagged: flagged, reason: reason}} <- McpClient.screen_vendor(value) do
        {:ok,
         %{
           rule: rule,
           passed: not flagged,
           detail: if(flagged, do: "Sanctions screening hit: #{reason}")
         }}
      end
    end
  end

  defp field_value(extracted, %{"role" => role, "name" => name}) do
    extracted
    |> Map.fetch!(role)
    |> Map.fetch!(String.to_existing_atom(name))
  end

  @doc """
  Entity match with a cheap string-similarity pre-filter in front of the
  LLM call: names that are clearly the same or clearly different (per
  `staged_match/2`) skip the LLM entirely; only the genuinely ambiguous
  middle band pays for a real call.
  """
  @spec entity_match(String.t(), String.t()) :: {:ok, EntityMatchResult.t()} | {:error, term()}
  def entity_match(name_a, name_b) do
    case staged_match(name_a, name_b) do
      {:ok, _result} = staged -> staged
      :ambiguous -> llm_entity_match(name_a, name_b)
    end
  end

  @doc """
  Pure, deterministic pre-filter: `String.jaro_distance/2` on normalized
  (downcased, trimmed, punctuation-stripped) names. Returns `:ambiguous`
  for anything not clearly on one side, which is the safe default — see
  the threshold calibration comment above.
  """
  @spec staged_match(String.t(), String.t()) ::
          {:ok, EntityMatchResult.t()} | :ambiguous
  def staged_match(name_a, name_b) do
    similarity = String.jaro_distance(normalize_name(name_a), normalize_name(name_b))

    cond do
      similarity >= @clear_match_threshold ->
        {:ok,
         %EntityMatchResult{
           match: true,
           explanation:
             "Normalized names match closely (similarity #{Float.round(similarity, 2)}) — skipped LLM call"
         }}

      similarity <= @clear_mismatch_threshold ->
        {:ok,
         %EntityMatchResult{
           match: false,
           explanation:
             "Normalized names are clearly different (similarity #{Float.round(similarity, 2)}) — skipped LLM call"
         }}

      true ->
        :ambiguous
    end
  end

  defp normalize_name(name) do
    name |> String.downcase() |> String.trim() |> String.replace(~r/[^\w\s]/, "")
  end

  defp llm_entity_match(name_a, name_b) do
    case Application.get_env(:document_compliance_engine, :agent_entity_match) do
      nil ->
        content =
          String.replace(@entity_match_prompt, "%{name_a}", name_a)
          |> String.replace("%{name_b}", name_b)

        Instructor.chat_completion(
          model: "gpt-4o-mini",
          response_model: EntityMatchResult,
          max_retries: 1,
          messages: [%{role: "user", content: content}]
        )

      fun ->
        fun.(name_a, name_b)
    end
  end

  @spec draft_explanation(ValidationResult.t()) :: String.t()
  def draft_explanation(%ValidationResult{} = validation) do
    findings = describe_findings(validation)

    case Application.get_env(:document_compliance_engine, :agent_draft_explanation) do
      nil -> llm_explanation(findings)
      fun -> fun.(findings)
    end
  end

  @spec describe_findings(ValidationResult.t()) :: String.t()
  def describe_findings(%ValidationResult{} = validation) do
    validation
    |> ValidationResult.failed_checks()
    |> Enum.map(& &1.detail)
    |> Enum.join("; ")
  end

  defp llm_explanation(findings) do
    content = String.replace(@explanation_prompt, "%{findings}", findings)

    case Instructor.chat_completion(
           model: "gpt-4o-mini",
           response_model: %{explanation: :string},
           max_retries: 1,
           messages: [%{role: "user", content: content}]
         ) do
      {:ok, %{explanation: explanation}} -> explanation
      # An explanation is advisory text on an already-decided pause — never
      # a reason to fail the run, so fall back to the raw findings.
      {:error, _reason} -> findings
    end
  end
end
