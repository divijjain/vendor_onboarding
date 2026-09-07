defmodule DocumentComplianceEngine.Agent.Checks do
  @moduledoc """
  Agent 2: interprets a document type's `validation_rules` against the
  extracted data. Four rule types:

    - `entity_match` — an LLM judgment comparing two named fields (e.g.
      the contract's and W-9's company names)
    - `mcp_tool` — calls one of the two known MCP tools
      (`validate_tax_id`/`screen_vendor`) against one named field
    - `format` — a pure, deterministic well-formedness check on one named
      field (`FormatValidators`), e.g. `iban`'s mod-97 checksum. Free and
      offline, so a field can carry one alongside any other rule.
    - `regex` — the same idea with a document-type-supplied pattern, for a
      field whose shape is specific to that document type rather than a
      general format worth naming a validator for
    - `not_expired` — the only rule whose answer depends on *when it runs*:
      an extracted date must not be in the past. A certificate of insurance
      that was valid when it was filed and has since lapsed is a real
      compliance finding, and no amount of reading the document alone
      produces it. `today` is injectable via `validate_all/4`'s `:today`
      option, so a fixture that expires "next year" doesn't quietly become
      a failing fixture the year after it was written

  The two tools themselves stay a fixed, known pair — only which
  document/field feeds them varies by document type, so their
  human-readable failure messages stay hardcoded per tool rather than
  generated generically.

  `validate_all/4` also runs four automatic checks on every extracted
  field, unconditionally — none is one of `validation_rules`, so none
  can be configured away per document type:

    - `grounded_extraction_checks/3` — every non-blank extracted string
      must appear in the source text it came from. `Extraction` prompts
      the model to pull fields "verbatim as written"; a field that
      doesn't appear in the source either broke that instruction or was
      invented outright. When the document type configures
      `shape_signals` for a role, this also requires at least one of
      that role's configured keywords to appear somewhere in the source —
      plain substring presence isn't enough on its own, since a long,
      multi-topic document (a résumé, say) can contain a real dollar
      figure or date that has nothing to do with the field it got mapped
      to. (Distinct
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
    - `declared_type_checks/3` — a value that isn't well-formed for the
      type its document type declared for the field (`extraction_schema`,
      `Agent.FieldTypes`). This is where a declared type gets its teeth:
      `Extraction` deliberately returns every value verbatim whatever its
      declared type, precisely so the value stays provable against the
      source document, which leaves *checking* the value's shape to this
      module. It runs the same `FormatValidators` a `format` rule does —
      a declared type is exactly "this field always carries that check",
      without a per-document-type rule entry to remember.
  """

  alias DocumentComplianceEngine.Agent.ExtractionSchema
  alias DocumentComplianceEngine.Agent.FieldTypes
  alias DocumentComplianceEngine.Agent.FormatValidators
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

  @doc """
  Runs every automatic check plus this document type's configured
  `validation_rules` against one run's extracted fields.

  The three pieces of run context the automatic checks need — `:shape_signals`,
  `:extraction_metadata` and `:extraction_schema` — are options rather than
  further positional arguments: each is optional, each defaults to "no such
  config", and a fourth and fifth trailing map would make every call site
  unreadable at exactly the point where getting the order wrong is silent
  (they are all plain maps).
  """
  @spec validate_all(%{String.t() => map()}, %{String.t() => String.t()}, [map()], keyword()) ::
          {:ok, ValidationResult.t()} | {:error, term()}
  def validate_all(extracted, documents, validation_rules, opts \\ []) do
    shape_signals = Keyword.get(opts, :shape_signals, %{})
    extraction_metadata = Keyword.get(opts, :extraction_metadata, %{})
    extraction_schema = Keyword.get(opts, :extraction_schema, %{})
    # The one rule that needs to know what day it is. Injectable so a
    # fixture's "expires next year" doesn't quietly become "expired" the
    # year after it was written.
    today = Keyword.get(opts, :today, Date.utc_today())

    automatic =
      grounded_extraction_checks(extracted, documents, shape_signals) ++
        extraction_completeness_checks(extracted) ++
        low_confidence_checks(extracted, extraction_metadata) ++
        declared_type_checks(extracted, extraction_schema, validation_rules)

    validation_rules
    |> Enum.reduce_while({:ok, automatic}, fn rule, {:ok, acc} ->
      case run_rule(rule, extracted, today) do
        {:ok, check} -> {:cont, {:ok, [check | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, checks} -> {:ok, %ValidationResult{checks: Enum.reverse(checks)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deterministic (no LLM) check that every non-blank extracted string field
  actually appears in the source text it was extracted from, case- and
  whitespace-insensitively. Runs against every field in `extracted`
  regardless of whether any configured `validation_rules` entry happens to
  reference it — the whole point is to catch a fabricated field a document
  type's config didn't think to check.

  When `shape_signals` configures keywords for a role, plain substring
  presence isn't enough — at least one of those keywords must also appear
  *somewhere* in the source document. A document with no real content for
  a role can still contain a real, verbatim number or date that means
  something else entirely (see CONTEXT.md's dated entry on the
  résumé-as-invoice case this closes); requiring some field-relevant
  vocabulary anywhere in the document is a cheap way to tell "this document
  is actually about this role" from "this value happens to be somewhere in
  a document about something else."

  This used to also require the matched keyword within a fixed byte window
  of the value, not just present anywhere in the document — dropped after
  a real, reproducible false positive: a genuinely correct, verbatim value
  (a due date) sat far enough from the nearest configured keyword, purely
  because of how that one document happened to phrase its label, to
  intermittently fall outside the window depending on exactly where the
  extracted value's own boundaries landed that call. Document-wide
  presence still catches the case this check exists for — the résumé
  fixture below has *zero* invoice keywords anywhere in it, not just none
  nearby — without being sensitive to exactly where in the document the
  value and the keyword each happen to sit. See CONTEXT.md's dated entry.
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
    String.contains?(source, value) and keyword_present?(source, shape)
  end

  defp keyword_present?(_source, nil), do: true
  defp keyword_present?(_source, shape) when map_size(shape) == 0, do: true

  defp keyword_present?(source, %{"keywords" => keywords}) do
    Enum.any?(keywords, &String.contains?(source, normalize_text(&1)))
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

  # A real calibration attempt was made (`Evals.Run.confidence_calibration/1`,
  # `mix eval.run`'s "Confidence calibration" section) — not the same
  # situation as the entity-match thresholds above, which had real
  # separation data to calibrate against. Across all 288 real (non-regex,
  # non-shape-gate-skipped) field confidences in the full 79-fixture
  # corpus, every single one was 0.90 or higher, and *zero* fields with a
  # genuine confidence value ever failed the grounding check — GPT-4o-mini
  # is uniformly high-confidence on every field it actually attempts in
  # this corpus, correct or not, so there is no natural separation point
  # in the data to set a threshold from. That makes 0.7 (or any number
  # below ~0.90) behaviorally identical here: this check has never fired
  # once against this corpus. Left at 0.7 rather than invented a
  # different number with equally no evidence behind it — the honest
  # finding is that self-reported confidence doesn't discriminate at all
  # in the data available, not that a better threshold is hiding
  # somewhere. `grounded_extraction_checks/3` is doing the real work;
  # this stays exactly the "complementary, not primary" signal the
  # moduledoc always said it was, now with data behind that instead of
  # a hunch. See CONTEXT.md's dated entry.
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

  @doc """
  Deterministic (no LLM, no network, no clock) check that every extracted
  value is well-formed for the type its document type declared for it in
  `extraction_schema` — the check that gives a declared type teeth.

  Runs against every typed field, whether or not `validation_rules`
  happens to name it: declaring `amount` a `number` *is* the instruction to
  check it, and having to also remember a matching `format` rule entry
  would make the declaration decorative. A field declared `"string"` has no
  shape to be wrong about and is skipped, as is a blank one
  (`extraction_completeness_checks/1` owns "the value never arrived", and
  reporting the same field twice for two reasons would only pad the
  reviewer's list).

  A field that *does* carry an explicit `format` rule naming the same
  validator is skipped here, so a document type that both declares the
  type and configures the rule reports one finding rather than two
  near-identical ones. A `format` rule naming a *different* validator is
  left alone — that's a deliberately additional check, not a duplicate.

  This asks a different question from `grounded_extraction_checks/3`, and
  neither subsumes the other — see `FormatValidators`' moduledoc: a
  hallucinated-but-well-formed date passes here and fails grounding; a
  verbatim typo in the source passes grounding and fails here.
  """
  @spec declared_type_checks(%{String.t() => map()}, map(), [map()]) :: [ValidationResult.check()]
  def declared_type_checks(extracted, extraction_schema, validation_rules \\ []) do
    explicit = explicitly_format_checked(validation_rules)

    for {role, fields} <- extracted,
        field_specs = ExtractionSchema.fields(extraction_schema, role),
        {field, value} <- fields,
        is_binary(value),
        not blank?(value),
        declared = ExtractionSchema.type(field_specs[Atom.to_string(field)]),
        validator = FieldTypes.format_validator(declared),
        is_binary(validator),
        not MapSet.member?(explicit, {role, Atom.to_string(field), validator}),
        detail <- type_error(validator, value) do
      %{
        rule: %{
          "type" => "declared_field_type",
          "field" => %{"role" => role, "name" => field},
          "declared_type" => declared
        },
        passed: false,
        detail: "Extracted #{field} for #{role} is declared as #{declared} — #{detail}"
      }
    end
  end

  # A list, not a `case`, so it can be the comprehension's last generator:
  # `[]` for a value that passes, one detail for one that doesn't.
  # `:unknown_validator` is unreachable — `FieldTypes` only ever hands back
  # a validator name `FormatValidators` declares, checked at compile time.
  defp type_error(validator, value) do
    case FormatValidators.validate(validator, value) do
      :ok -> []
      {:error, detail} when is_binary(detail) -> [detail]
    end
  end

  defp explicitly_format_checked(validation_rules) do
    for %{"type" => "format", "validator" => validator, "field" => field} <- validation_rules,
        %{"role" => role, "name" => name} = field,
        into: MapSet.new(),
        do: {role, name, validator}
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
  defp run_rule(%{"type" => "entity_match", "fields" => [a, b]} = rule, extracted, _today) do
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
         extracted,
         _today
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
         extracted,
         _today
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

  # Unlike the rules above, these two reach nothing external, so there's no
  # blank-guard-before-the-call reason here — a blank field is still a
  # synthesized failure rather than a silent pass, because "the field we
  # were told to format-check never arrived" is itself a finding.
  defp run_rule(
         %{"type" => "format", "validator" => validator, "field" => field} = rule,
         extracted,
         _today
       ) do
    value = field_value(extracted, field)

    if blank?(value) do
      {:ok,
       %{
         rule: rule,
         passed: false,
         detail: "Cannot check #{validator} format — the field was not extracted."
       }}
    else
      case FormatValidators.validate(validator, value) do
        :ok ->
          {:ok, %{rule: rule, passed: true, detail: nil}}

        {:error, :unknown_validator} ->
          # A document type naming a validator that doesn't exist is a config
          # bug. Failing the run surfaces it immediately; passing or failing
          # the check silently would let a rule the operator believes is
          # enforcing something do nothing at all.
          {:error, {:unknown_format_validator, validator}}

        {:error, detail} ->
          {:ok, %{rule: rule, passed: false, detail: detail}}
      end
    end
  end

  # The only rule that depends on when it is run. A certificate that was
  # valid when it was filed and has since lapsed is a real compliance
  # finding, and it is not one any amount of looking at the document alone
  # can produce.
  defp run_rule(%{"type" => "not_expired", "field" => field} = rule, extracted, today) do
    value = field_value(extracted, field)

    cond do
      blank?(value) ->
        {:ok,
         %{rule: rule, passed: false, detail: "Cannot check expiry — the date was not extracted."}}

      true ->
        case FormatValidators.parse_date(String.trim(value)) do
          {:ok, date} -> {:ok, expiry_check(rule, date, today, value)}
          # Undecidable, not invalid: see `FormatValidators.parse_date/1` on
          # why an ambiguous slash date is reported rather than read one way.
          :error -> {:ok, %{rule: rule, passed: false, detail: undecidable_detail(value)}}
        end
    end
  end

  defp run_rule(
         %{"type" => "regex", "pattern" => pattern, "field" => field} = rule,
         extracted,
         _today
       ) do
    value = field_value(extracted, field)

    with {:ok, compiled} <- compile_pattern(pattern) do
      cond do
        blank?(value) ->
          {:ok,
           %{
             rule: rule,
             passed: false,
             detail: "Cannot check pattern #{pattern} — the field was not extracted."
           }}

        Regex.match?(compiled, String.trim(value)) ->
          {:ok, %{rule: rule, passed: true, detail: nil}}

        true ->
          {:ok,
           %{
             rule: rule,
             passed: false,
             detail: "#{inspect(value)} does not match the required pattern #{pattern}."
           }}
      end
    end
  end

  defp expiry_check(rule, date, today, value) do
    if Date.compare(date, today) == :lt do
      %{
        rule: rule,
        passed: false,
        detail:
          "Expired: #{inspect(value)} is #{Date.diff(today, date)} day(s) before today " <>
            "(#{Date.to_iso8601(today)})."
      }
    else
      %{rule: rule, passed: true, detail: nil}
    end
  end

  defp undecidable_detail(value) do
    "Cannot tell whether #{inspect(value)} has passed — it is not a date that can be read " <>
      "one way only, and guessing which reading was meant would decide the answer."
  end

  # An uncompilable pattern is a config bug, same as an unknown validator
  # name — surfaced loudly rather than quietly matching nothing.
  defp compile_pattern(pattern) do
    case Regex.compile(pattern) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, _reason} -> {:error, {:invalid_regex_rule, pattern}}
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
