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

  describe "field_confidences / confidence_calibration" do
    setup do
      # A real, contrived-but-realistic extraction: contract fields both
      # genuinely grounded (present in the contract text) at different
      # confidences; the w9's company_name is fabricated (never appears in
      # the w9 text) at *high* self-reported confidence, on purpose --
      # proving the calibration data is about whether confidence predicts
      # grounding, not confidence predicting itself.
      stub_defaults(
        extract: fn
          "contract", _schema, _text ->
            {:ok, %{company_name: "Acme Corp", payment_terms: "Net 30"},
             %{
               company_name: %{confidence: 0.95, source_quote: "Acme Corp"},
               payment_terms: %{confidence: 0.4, source_quote: "Net 30"}
             }}

          "w9", _schema, _text ->
            {:ok, %{company_name: "Totally Fabricated Inc", tax_id: "12-3456789"},
             %{
               company_name: %{confidence: 0.99, source_quote: "n/a"},
               tax_id: %{confidence: 1.0, source_quote: "12-3456789"}
             }}
        end
      )

      :ok
    end

    test "records real per-field confidence paired with whether that exact field was grounded" do
      fixture = Enum.find(Fixtures.vendor_contract_w9(), &(&1.id == "clean-01"))
      result = Run.run_fixture(fixture)

      by_field = Map.new(result.field_confidences, &{{&1.role, &1.field}, &1})

      assert by_field[{"contract", :company_name}] == %{
               role: "contract",
               field: :company_name,
               confidence: 0.95,
               grounded: true
             }

      assert by_field[{"contract", :payment_terms}].grounded == true
      assert by_field[{"contract", :payment_terms}].confidence == 0.4

      assert by_field[{"w9", :company_name}] == %{
               role: "w9",
               field: :company_name,
               confidence: 0.99,
               grounded: false
             }

      # tax_id is deliberately excluded -- its confidence can't be told
      # apart from a regex-synthesized one, see Run.field_confidences/4.
      refute Map.has_key?(by_field, {"w9", :tax_id})
    end

    test "confidence_calibration/1 buckets by grounded status across results, excludes errored fixtures" do
      fixture = Enum.find(Fixtures.vendor_contract_w9(), &(&1.id == "clean-01"))
      results = [Run.run_fixture(fixture), %Run.Result{fixture: fixture, error: "boom"}]

      calibration = Run.confidence_calibration(results)

      assert Enum.sort(calibration.grounded) == [0.4, 0.95]
      assert calibration.ungrounded == [0.99]
    end
  end

  describe "invoice" do
    # Mirrors `SanctionsDb.Server.screen/1`'s real watchlist and fuzzy-match
    # behavior (the two apps are genuinely separate Mix projects — see
    # CLAUDE.md — so this can't just import that module; kept in sync by
    # hand, same as any other cross-app boundary here).
    @sanctioned ["rogue exports llc", "north star trading co"]
    @fuzzy_match_threshold 0.80

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

    defp fake_screen_vendor(name) do
      normalized = name |> String.trim() |> String.downcase()

      similarity =
        @sanctioned |> Enum.map(&String.jaro_distance(normalized, &1)) |> Enum.max()

      cond do
        similarity == 1.0 ->
          {:ok, %{flagged: true, reason: "Matched sanctions watchlist entry"}}

        similarity >= @fuzzy_match_threshold ->
          {:ok,
           %{
             flagged: true,
             reason: "Possible sanctions watchlist match — flagged for manual review"
           }}

        true ->
          {:ok, %{flagged: false, reason: nil}}
      end
    end

    setup do
      stub_defaults(
        extract: fn "invoice", _schema, text -> parse_invoice(text) end,
        screen_vendor: &fake_screen_vendor/1
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
      assert accuracy[{"invoice", "invoice_sanctions_evasion"}] == %{total: 2, correct: 2}
      assert accuracy[{"invoice", "invoice_malformed"}] == %{total: 3, correct: 3}
      assert accuracy[{"invoice", "invoice_wrong_type"}] == %{total: 3, correct: 3}
    end

    test "extracted fields are grounded in source for the clean and sanctions-hit buckets" do
      results =
        Fixtures.invoice()
        |> Run.run_all()
        |> Enum.filter(
          &(&1.fixture.bucket in [
              "invoice_clean",
              "invoice_sanctions_hit",
              "invoice_sanctions_evasion"
            ])
        )

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

  describe "scanned" do
    # What each fixture's image actually renders (see priv/eval_fixtures/scanned
    # and Fixtures.scanned/0) — stood in for here via a fake vision_transcribe_fun
    # so this test proves the harness's own plumbing (build_documents -> PdfText
    # -> reactor) without an OpenAI key, same disclaimer as the rest of this file.
    @scanned_transcriptions %{
      "scanned-clean-01" => """
      INVOICE

      Bill To: Buyer Inc.
      Vendor: Golden Gate Supplies Co.
      Invoice Number: INV-7781
      Amount Due: $4,120.00
      Due Date: 2026-09-25
      """,
      "scanned-clean-02" => """
      INVOICE

      Bill To: Buyer Inc.
      Vendor: Northwind Traders Ltd.
      Invoice Number: INV-7782
      Amount Due: $980.50
      Due Date: 2026-10-02
      """,
      "scanned-sanctions-01" => """
      INVOICE

      Bill To: Buyer Inc.
      Vendor: Rogue Exports LLC
      Invoice Number: INV-7783
      Amount Due: $2,500.00
      Due Date: 2026-09-18
      """,
      "scanned-malformed-01" => """
      INVOICE

      Bill To: Buyer Inc.
      Vendor: Fairview Trading Co.
      """,
      "scanned-layout-table-01" => """
      INVOICE

      Vendor: Ironbridge Manufacturing Co.

      Description       Qty   Rate    Amount
      Machine parts     10    45.00   450.00

      Total Due: $450.00

      Payment due by 2026-09-20.
      """,
      "scanned-layout-alt-01" => """
      SABINE POINT LOGISTICS LLC
      123 Harbor Way, Port City

      INVOICE #INV-9042
      Date Issued: 2026-09-10
      Client: Buyer Inc.

      Balance Due: $1,275.00
      Please remit by 2026-09-30.

      Questions about this invoice? Contact your vendor at billing@sabinepoint.example.
      """,
      "scanned-photo-skew-01" => """
      INVOICE

      Bill To: Buyer Inc.
      Vendor: Crestline Industrial Parts Co.
      Invoice Number: INV-6620
      Amount Due: $3,340.00
      Due Date: 2026-09-12
      """,
      "scanned-photo-glare-01" => """
      INVOICE

      Bill To: Buyer Inc.
      Vendor: Meadowlark Business Services
      Invoice Number: INV-6741
      Amount Due: $1,890.00
      Due Date: 2026-09-22
      """
    }

    # Extracted fields per fixture, standing in for a real extraction call —
    # `parse_invoice/1`'s regexes assume the original fixed template
    # ("Vendor:", "Amount Due:", ...), which the layout-diverse fixtures
    # deliberately don't use (see Fixtures.scanned/0), so this is keyed by
    # fixture id instead. `scanned-layout-table-01` genuinely comes back
    # with `invoice_number: nil` here — that mirrors a real finding (the
    # vision model dropped that fixture's header text box on a real run,
    # see CONTEXT.md's dated entry), not a fake left incomplete by mistake.
    @scanned_fields %{
      "scanned-clean-01" => %{
        vendor_name: "Golden Gate Supplies Co.",
        invoice_number: "INV-7781",
        amount: "$4,120.00",
        due_date: "2026-09-25"
      },
      "scanned-clean-02" => %{
        vendor_name: "Northwind Traders Ltd.",
        invoice_number: "INV-7782",
        amount: "$980.50",
        due_date: "2026-10-02"
      },
      "scanned-sanctions-01" => %{
        vendor_name: "Rogue Exports LLC",
        invoice_number: "INV-7783",
        amount: "$2,500.00",
        due_date: "2026-09-18"
      },
      "scanned-malformed-01" => %{
        vendor_name: "Fairview Trading Co.",
        invoice_number: nil,
        amount: nil,
        due_date: nil
      },
      "scanned-layout-table-01" => %{
        vendor_name: "Ironbridge Manufacturing Co.",
        invoice_number: nil,
        amount: "$450.00",
        due_date: "2026-09-20"
      },
      "scanned-layout-alt-01" => %{
        vendor_name: "SABINE POINT LOGISTICS LLC",
        invoice_number: "INV-9042",
        amount: "$1,275.00",
        due_date: "2026-09-30"
      },
      "scanned-photo-skew-01" => %{
        vendor_name: "Crestline Industrial Parts Co.",
        invoice_number: "INV-6620",
        amount: "$3,340.00",
        due_date: "2026-09-12"
      },
      "scanned-photo-glare-01" => %{
        vendor_name: "Meadowlark Business Services",
        invoice_number: "INV-6741",
        amount: "$1,890.00",
        due_date: "2026-09-22"
      }
    }

    test "each fixture's image is read off disk, transcribed, and reaches its expected decision" do
      for fixture <- Fixtures.scanned() do
        transcription = Map.fetch!(@scanned_transcriptions, fixture.id)
        fields = Map.fetch!(@scanned_fields, fixture.id)

        stub_defaults(
          extract: fn "invoice", _schema, _text -> {:ok, fields} end,
          screen_vendor: &fake_screen_vendor/1,
          vision_transcribe_fun: fn _bytes, _mime_type -> {:ok, transcription} end
        )

        result = Run.run_fixture(fixture)

        assert result.error == nil, "#{fixture.id} errored: #{result.error}"

        assert result.decision == fixture.expected_decision,
               "#{fixture.id}: expected #{fixture.expected_decision}, got #{result.decision}"
      end
    end

    test "build_documents reads the real image bytes off disk rather than a nil fixture.documents" do
      test_pid = self()
      fixture = Enum.find(Fixtures.scanned(), &(&1.id == "scanned-clean-01"))
      expected_size = fixture.image_paths["invoice"] |> File.read!() |> byte_size()

      stub_defaults(
        extract: fn "invoice", _schema, _text ->
          {:ok, Map.fetch!(@scanned_fields, "scanned-clean-01")}
        end,
        vision_transcribe_fun: fn bytes, mime_type ->
          send(test_pid, {:transcribed, byte_size(bytes), mime_type})
          {:ok, @scanned_transcriptions["scanned-clean-01"]}
        end
      )

      Run.run_fixture(fixture)

      assert_received {:transcribed, ^expected_size, "image/png"}
    end

    test "the photo-realistic bucket's JPEG fixture routes as image/jpeg, not image/png" do
      test_pid = self()
      fixture = Enum.find(Fixtures.scanned(), &(&1.id == "scanned-photo-skew-01"))

      stub_defaults(
        extract: fn "invoice", _schema, _text ->
          {:ok, Map.fetch!(@scanned_fields, "scanned-photo-skew-01")}
        end,
        vision_transcribe_fun: fn _bytes, mime_type ->
          send(test_pid, {:transcribed, mime_type})
          {:ok, @scanned_transcriptions["scanned-photo-skew-01"]}
        end
      )

      Run.run_fixture(fixture)

      assert_received {:transcribed, "image/jpeg"}
    end
  end
end
