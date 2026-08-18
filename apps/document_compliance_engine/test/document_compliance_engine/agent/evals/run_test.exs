defmodule DocumentComplianceEngine.Agent.Evals.RunTest do
  @moduledoc """
  Proves the harness's own plumbing (fixture -> pipeline -> scoring) is
  correct, using injected fake agent calls — not a claim that these fakes
  match real GPT-4o-mini/Claude Sonnet behavior. Running the harness for
  real needs OPENAI_API_KEY (+ ANTHROPIC_API_KEY for the judge tier).

  `vendor_contract_w9` fixtures are run through `Fixtures.vendor_contract_w9/0`
  explicitly (not the bare `Fixtures.all/0` default), so this file's exact
  fixture counts stay meaningful regardless of how many other document
  types the fixture set grows to cover — see the `invoice` describe block
  below for that type's own scoped coverage.
  """

  use DocumentComplianceEngine.DataCase, async: false

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.Agent.Evals.{Fixtures, Run}
  alias DocumentComplianceEngine.Agent.Schemas.EntityMatchResult

  @suffixes ~w(inc llc corp corporation co company ltd incorporated group)
  @stopwords ~w(the)
  @synonyms %{"tech" => "technology", "svc" => "service"}
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
    |> Enum.reject(&(&1 in @suffixes or &1 in @stopwords))
    |> Enum.map(&Map.get(@synonyms, &1, &1))
    |> MapSet.new()
  end

  defp parse_contract(text) do
    [_, name] = Regex.run(~r/and (.+?) \("Vendor/, text)
    [_, terms] = Regex.run(~r/Payment Terms: (.+)/, text)
    [_, liability] = Regex.run(~r/Liability: (.+)/, text)

    {:ok, %{company_name: name, payment_terms: terms, liability_clauses: liability}}
  end

  defp parse_w9(text) do
    [_, name] = Regex.run(~r/1\. Name of entity: (.*)/, text)
    [_, tax_id] = Regex.run(~r/2\. Taxpayer Identification Number \(EIN\): (.*)/, text)

    {:ok, %{company_name: name, tax_id: tax_id}}
  end

  setup do
    stub_defaults(
      extract: fn
        "contract", _schema, text -> parse_contract(text)
        "w9", _schema, text -> parse_w9(text)
      end,
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

  describe "vendor_contract_w9" do
    test "every fixture reaches its expected decision with a well-behaved agent" do
      for result <- Run.run_all(Fixtures.vendor_contract_w9()) do
        assert result.error == nil, "#{result.fixture.id} errored: #{result.error}"

        assert result.decision == result.fixture.expected_decision,
               "#{result.fixture.id}: expected #{result.fixture.expected_decision}, got #{result.decision}"
      end
    end

    test "bucket accuracy reports 100% when every decision matches" do
      accuracy = Run.run_all(Fixtures.vendor_contract_w9()) |> Run.bucket_accuracy()

      assert accuracy[{"vendor_contract_w9", "clean"}] == %{total: 20, correct: 20}
      assert accuracy[{"vendor_contract_w9", "mismatch"}] == %{total: 15, correct: 15}
      assert accuracy[{"vendor_contract_w9", "formatting"}] == %{total: 12, correct: 12}
      assert accuracy[{"vendor_contract_w9", "malformed"}] == %{total: 8, correct: 8}
    end

    test "tax ids are extracted verbatim for every well-formed fixture" do
      well_formed =
        Fixtures.vendor_contract_w9()
        |> Run.run_all()
        |> Enum.reject(&(&1.fixture.bucket == "malformed"))

      assert length(well_formed) == 47
      assert Enum.all?(well_formed, & &1.tax_id_verbatim_ok)
    end

    test "extracted fields are grounded in source for every well-behaved fixture" do
      results = Run.run_all(Fixtures.vendor_contract_w9())
      assert Enum.all?(results, & &1.fields_grounded)
    end

    test "the formatting bucket is not flagged as a mismatch" do
      # The false-positive control — this is what makes a 100% accuracy
      # claim credible rather than cherry-picked.
      formatting =
        Fixtures.vendor_contract_w9()
        |> Run.run_all()
        |> Enum.filter(&(&1.fixture.bucket == "formatting"))

      assert length(formatting) == 12
      assert Enum.all?(formatting, &(&1.decision == "approved"))
      assert Enum.all?(formatting, & &1.entity_match)
    end

    test "a raising extractor is recorded as graceful degradation, not a crash" do
      stub_defaults(
        extract: fn
          "contract", _schema, _text -> {:error, "simulated extraction failure"}
          "w9", _schema, text -> parse_w9(text)
        end
      )

      [result] = Run.run_all([hd(Fixtures.vendor_contract_w9())])

      assert result.error =~ "simulated extraction failure"
      assert result.decision == nil
    end

    test "judge_scores only scores completed fixtures with a known expectation" do
      # stub/1, not stub_defaults/1 — the setup's parsing extractors must
      # stay in place or nothing mismatches and no explanation is drafted.
      stub(judge_fun: fn _criteria, _evidence -> {:ok, %{score: 0.9, reasoning: "ok"}} end)

      scores = Fixtures.vendor_contract_w9() |> Run.run_all() |> Run.judge_scores()

      # 47 fixtures have a known expected_entity_match (excludes the 8 malformed).
      assert length(scores.entity_match.scores) == 47
      assert Enum.all?(scores.entity_match.scores, &(&1 == 0.9))
      assert scores.entity_match.errors == []

      # Groundedness is scored wherever an explanation was actually
      # drafted — the mismatch bucket (15) and the malformed bucket (8),
      # since clean/formatting auto-approve with no explanation at all.
      assert length(scores.groundedness.scores) == 23
      assert scores.groundedness.errors == []
    end

    test "judge_scores surfaces a failed judge call instead of silently dropping it" do
      stub(judge_fun: fn _criteria, _evidence -> {:error, :rate_limited} end)

      scores = Fixtures.vendor_contract_w9() |> Run.run_all() |> Run.judge_scores()

      assert scores.entity_match.scores == []
      assert scores.entity_match.errors == List.duplicate(:rate_limited, 47)

      assert scores.groundedness.scores == []
      assert scores.groundedness.errors == List.duplicate(:rate_limited, 23)
    end
  end

  describe "invoice" do
    # Mirrors `SanctionsDb.Server.screen/1`'s real watchlist exactly (the
    # two apps are genuinely separate Mix projects — see CLAUDE.md — so
    # this can't just import that module; kept in sync by hand, same as
    # any other cross-app boundary here).
    @sanctioned MapSet.new(["rogue exports llc", "north star trading co"])

    defp parse_invoice(text) do
      [_, vendor] = Regex.run(~r/Vendor: (.+)/, text)
      invoice_number = Regex.run(~r/Invoice Number: (.+)/, text)
      amount = Regex.run(~r/Amount Due: (.+)/, text)
      due_date = Regex.run(~r/Due Date: (.+)/, text)

      {:ok,
       %{
         vendor_name: vendor,
         invoice_number: invoice_number && Enum.at(invoice_number, 1),
         amount: amount && Enum.at(amount, 1),
         due_date: due_date && Enum.at(due_date, 1)
       }}
    end

    setup do
      stub_defaults(
        extract: fn "invoice", _schema, text -> parse_invoice(text) end,
        screen_vendor: fn name ->
          flagged = MapSet.member?(@sanctioned, name |> String.trim() |> String.downcase())
          {:ok, %{flagged: flagged, reason: if(flagged, do: "Matched sanctions watchlist entry")}}
        end
      )

      :ok
    end

    test "every fixture reaches its expected decision" do
      for result <- Run.run_all(Fixtures.invoice()) do
        assert result.error == nil, "#{result.fixture.id} errored: #{result.error}"

        assert result.decision == result.fixture.expected_decision,
               "#{result.fixture.id}: expected #{result.fixture.expected_decision}, got #{result.decision}"
      end
    end

    test "bucket accuracy reports 100% when every decision matches" do
      accuracy = Run.run_all(Fixtures.invoice()) |> Run.bucket_accuracy()

      assert accuracy[{"invoice", "invoice_clean"}] == %{total: 6, correct: 6}
      assert accuracy[{"invoice", "invoice_sanctions_hit"}] == %{total: 2, correct: 2}
      assert accuracy[{"invoice", "invoice_malformed"}] == %{total: 3, correct: 3}
      assert accuracy[{"invoice", "invoice_wrong_type"}] == %{total: 3, correct: 3}
    end

    test "extracted fields are grounded in source for the clean and sanctions-hit buckets" do
      results =
        Fixtures.invoice()
        |> Run.run_all()
        |> Enum.filter(&(&1.fixture.bucket in ["invoice_clean", "invoice_sanctions_hit"]))

      assert Enum.all?(results, & &1.fields_grounded)
    end

    test "entity_match and tax_id_verbatim_ok are not applicable to invoice fixtures" do
      results = Run.run_all(Fixtures.invoice())

      assert Enum.all?(results, &is_nil(&1.entity_match))
      assert Enum.all?(results, &is_nil(&1.tax_id_verbatim_ok))
    end

    test "the wrong-document-type bucket never reaches the LLM" do
      test_pid = self()

      stub_defaults(
        extract: fn "invoice", _schema, text ->
          send(test_pid, :extract_called)
          parse_invoice(text)
        end
      )

      wrong_type_fixtures = Enum.filter(Fixtures.invoice(), &(&1.bucket == "invoice_wrong_type"))
      results = Run.run_all(wrong_type_fixtures)

      assert Enum.all?(results, &(&1.decision == "needs_review"))
      assert Enum.all?(results, &(&1.findings =~ "may not actually match"))
      refute_received :extract_called
    end
  end
end
