defmodule DocumentComplianceEngine.Agent.ClassificationTest do
  use ExUnit.Case, async: false

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.Agent.Classification

  defp candidate(slug, keywords, min_matches \\ 2) do
    %{
      "slug" => slug,
      "name" => slug,
      "description" => "A #{slug} document.",
      "extraction_schema" => %{slug => %{"field" => %{"type" => "string"}}},
      "validation_rules" => [],
      "shape_signals" => %{slug => %{"keywords" => keywords, "min_matches" => min_matches}}
    }
  end

  defp candidates do
    [
      candidate("invoice", ["invoice", "amount due", "bill to"]),
      candidate("receipt", ["receipt", "change due", "thank you"])
    ]
  end

  describe "a caller-supplied slug" do
    test "is honoured without spending a classification call" do
      test_pid = self()
      stub(classify: fn _text, _candidates -> send(test_pid, :called) end)

      assert {:ok, result} =
               Classification.classify(%{"invoice" => "anything"}, candidates(), "receipt")

      assert result.slug == "receipt"
      assert result.source == :caller
      assert result.confidence == 1.0
      assert result.confident?

      refute_received :called
    end

    test "is still checked against the registry, so a typo is loud" do
      assert {:error, {:unknown_document_type, "recipt"}} =
               Classification.classify(%{"invoice" => "anything"}, candidates(), "recipt")
    end
  end

  describe "the deterministic shape-signal pre-filter" do
    test "classifies without an LLM call when exactly one candidate matches" do
      test_pid = self()
      stub(classify: fn _text, _candidates -> send(test_pid, :called) end)

      documents = %{"document" => "INVOICE\nBill To: Buyer Inc.\nAmount Due: 1,000.00"}

      assert {:ok, result} = Classification.classify(documents, candidates())
      assert result.slug == "invoice"
      assert result.source == :shape_signals
      assert result.confident?

      refute_received :called
    end

    test "defers to the LLM when several candidates match" do
      # Deliberately contains enough of both vocabularies to clear both
      # gates — the pre-filter's whole rule is "an unambiguous majority of
      # one", and this isn't one.
      documents = %{
        "document" =>
          "INVOICE / RECEIPT\nBill To: Buyer\nAmount Due: 10\nThank you\nChange due: 0"
      }

      stub(
        classify: fn _text, _candidates ->
          {:ok, %{slug: "receipt", confidence: 0.9, reasoning: "says receipt"}}
        end
      )

      assert {:ok, result} = Classification.classify(documents, candidates())
      assert result.slug == "receipt"
      assert result.source == :llm
    end

    test "defers to the LLM when no candidate matches" do
      stub(
        classify: fn _text, _candidates ->
          {:ok, %{slug: "invoice", confidence: 0.8, reasoning: "best guess"}}
        end
      )

      assert {:ok, result} =
               Classification.classify(%{"document" => "an unrelated memo"}, candidates())

      assert result.source == :llm
    end

    test "a candidate with no shape_signals configured can never win the pre-filter" do
      untyped = %{candidate("memo", []) | "shape_signals" => %{}}

      stub(
        classify: fn _text, _candidates ->
          {:ok, %{slug: "memo", confidence: 0.9, reasoning: "a memo"}}
        end
      )

      # Only `memo` could plausibly match everything; it must not short-circuit.
      assert {:ok, result} = Classification.classify(%{"d" => "anything at all"}, [untyped])
      assert result.source == :llm
    end
  end

  describe "confidence" do
    test "a score below the threshold is not confident, but still names its best guess" do
      stub(
        classify: fn _text, _candidates ->
          {:ok, %{slug: "invoice", confidence: 0.4, reasoning: "could be either"}}
        end
      )

      assert {:ok, result} = Classification.classify(%{"d" => "ambiguous"}, candidates())
      assert result.slug == "invoice"
      refute result.confident?
      assert result.reasoning == "could be either"
    end

    test "a score at the threshold is confident" do
      stub(
        classify: fn _text, _candidates ->
          {:ok,
           %{slug: "invoice", confidence: Classification.confidence_threshold(), reasoning: ""}}
        end
      )

      assert {:ok, %{confident?: true}} = Classification.classify(%{"d" => "x"}, candidates())
    end

    test "a slug outside the registry is 'could not classify', never coerced to a real type" do
      stub(
        classify: fn _text, _candidates ->
          {:ok, %{slug: "unknown", confidence: 0.95, reasoning: "none of these fit"}}
        end
      )

      assert {:ok, result} = Classification.classify(%{"d" => "a résumé"}, candidates())
      assert result.slug == nil
      refute result.confident?
      assert result.confidence == 0.0
      assert result.reasoning == "none of these fit"
    end

    test "an LLM error is an error, not a silent low-confidence guess" do
      stub(classify: fn _text, _candidates -> {:error, :boom} end)

      assert {:error, :boom} = Classification.classify(%{"d" => "x"}, candidates())
    end
  end

  describe "prompt/2" do
    test "gives the model each candidate's slug and semantic description" do
      prompt = Classification.prompt("SOME DOCUMENT", candidates())

      assert prompt =~ "- invoice: A invoice document."
      assert prompt =~ "- receipt: A receipt document."
      assert prompt =~ "SOME DOCUMENT"
      # The escape hatch matters as much as the candidates: without it the
      # model has to pick one of them however wrong they all are.
      assert prompt =~ ~s(answer with the slug "unknown")
    end
  end

  describe "candidates/1" do
    test "presents rows as string-keyed config, the shape the checkpoint stores" do
      document_type = %DocumentComplianceEngine.DocumentTypes.Schema.DocumentType{
        slug: "invoice",
        name: "Vendor invoice",
        description: "A commercial invoice.",
        extraction_schema: %{"invoice" => %{"amount" => %{"type" => "monetary_amount"}}},
        validation_rules: [],
        shape_signals: %{}
      }

      assert [candidate] = Classification.candidates([document_type])
      assert candidate["slug"] == "invoice"
      assert candidate["description"] == "A commercial invoice."
      assert candidate["extraction_schema"]["invoice"]["amount"]["type"] == "monetary_amount"
    end
  end
end
