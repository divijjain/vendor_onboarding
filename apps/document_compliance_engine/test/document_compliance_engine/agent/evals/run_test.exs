defmodule DocumentComplianceEngine.Agent.Evals.RunTest do
  @moduledoc """
  Proves the harness's own plumbing (fixture -> pipeline -> scoring) is
  correct, using injected fake agent calls — not a claim that these fakes
  match real GPT-4o-mini/Claude Sonnet behavior. Running the harness for
  real needs OPENAI_API_KEY (+ ANTHROPIC_API_KEY for the judge tier).
  """

  use ExUnit.Case, async: false

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.Agent.Evals.Run

  alias DocumentComplianceEngine.Agent.Schemas.{
    ContractExtraction,
    EntityMatchResult,
    W9Extraction
  }

  @suffixes ~w(inc llc corp corporation co ltd group)
  @synonyms %{"tech" => "technology"}
  @ein_pattern ~r/^\d{2}-\d{7}$/

  # Normalized token-set comparison: a stand-in for the entity-match LLM
  # that gets the formatting bucket right without a real model.
  defp normalize(name) do
    name
    |> String.downcase()
    |> String.replace("&", " and ")
    |> String.replace(",", " ")
    |> then(&Regex.scan(~r/[a-z0-9]+/, &1))
    |> List.flatten()
    |> Enum.reject(&(&1 in @suffixes))
    |> Enum.map(&Map.get(@synonyms, &1, &1))
    |> MapSet.new()
  end

  defp parse_contract(text) do
    [_, name] = Regex.run(~r/and (.+?) \("Vendor/, text)
    [_, terms] = Regex.run(~r/Payment Terms: (.+)/, text)
    [_, liability] = Regex.run(~r/Liability: (.+)/, text)

    {:ok,
     %ContractExtraction{
       company_name: name,
       payment_terms: terms,
       liability_clauses: liability
     }}
  end

  defp parse_w9(text) do
    [_, name] = Regex.run(~r/1\. Name of entity: (.*)/, text)
    [_, tax_id] = Regex.run(~r/2\. Taxpayer Identification Number \(EIN\): (.*)/, text)

    {:ok, %W9Extraction{company_name: name, tax_id: tax_id}}
  end

  setup do
    stub_defaults(
      extract_contract: &parse_contract/1,
      extract_w9: &parse_w9/1,
      entity_match: fn contract_name, w9_name ->
        match = normalize(contract_name) == normalize(w9_name)

        {:ok,
         %EntityMatchResult{
           match: match,
           explanation: "fake normalized token-set comparison"
         }}
      end,
      validate_tax_id: fn tax_id ->
        {:ok, %{valid: Regex.match?(@ein_pattern, String.trim(tax_id))}}
      end
    )

    :ok
  end

  test "every fixture reaches its expected decision with a well-behaved agent" do
    for result <- Run.run_all() do
      assert result.error == nil, "#{result.fixture.id} errored: #{result.error}"

      assert result.decision == result.fixture.expected_decision,
             "#{result.fixture.id}: expected #{result.fixture.expected_decision}, got #{result.decision}"
    end
  end

  test "bucket accuracy reports 100% when every decision matches" do
    accuracy = Run.run_all() |> Run.bucket_accuracy()

    assert accuracy["clean"] == %{total: 10, correct: 10}
    assert accuracy["mismatch"] == %{total: 5, correct: 5}
    assert accuracy["formatting"] == %{total: 3, correct: 3}
    assert accuracy["malformed"] == %{total: 2, correct: 2}
  end

  test "tax ids are extracted verbatim for every well-formed fixture" do
    well_formed = Enum.reject(Run.run_all(), &(&1.fixture.bucket == "malformed"))

    assert length(well_formed) == 18
    assert Enum.all?(well_formed, & &1.tax_id_verbatim_ok)
  end

  test "the formatting bucket is not flagged as a mismatch" do
    # The false-positive control — this is what makes a 100% accuracy
    # claim credible rather than cherry-picked.
    formatting = Enum.filter(Run.run_all(), &(&1.fixture.bucket == "formatting"))

    assert length(formatting) == 3
    assert Enum.all?(formatting, &(&1.decision == "approved"))
    assert Enum.all?(formatting, & &1.entity_match)
  end

  test "a raising extractor is recorded as graceful degradation, not a crash" do
    stub_defaults(extract_contract: fn _text -> {:error, "simulated extraction failure"} end)

    [result] = Run.run_all([hd(DocumentComplianceEngine.Agent.Evals.Fixtures.all())])

    assert result.error =~ "simulated extraction failure"
    assert result.decision == nil
  end

  test "judge_scores only scores completed fixtures with a known expectation" do
    # stub/1, not stub_defaults/1 — the setup's parsing extractors must
    # stay in place or nothing mismatches and no explanation is drafted.
    stub(judge_fun: fn _criteria, _evidence -> {:ok, %{score: 0.9, reasoning: "ok"}} end)

    scores = Run.run_all() |> Run.judge_scores()

    # 18 fixtures have a known expected_entity_match (excludes the 2 malformed).
    assert length(scores.entity_match) == 18
    assert Enum.all?(scores.entity_match, &(&1 == 0.9))

    # Groundedness is only scored where an explanation was actually
    # drafted — the mismatch bucket, since clean/formatting auto-approve.
    assert length(scores.groundedness) == 5
  end
end
