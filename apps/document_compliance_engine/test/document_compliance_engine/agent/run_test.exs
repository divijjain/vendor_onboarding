defmodule DocumentComplianceEngine.Agent.RunTest do
  use DocumentComplianceEngine.DataCase, async: false

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.Agent.Checkpoint.Repository
  alias DocumentComplianceEngine.Agent.Run

  @document_type_slug "vendor_contract_w9"

  setup do
    # Capture reported results instead of writing through to AgentRuns —
    # these tests use bare integers as document_job_id, not real rows.
    test_pid = self()

    Application.put_env(:document_compliance_engine, :agent_callback_fun, fn payload ->
      Kernel.send(test_pid, {:callback, payload})
      {:ok, :captured}
    end)

    on_exit(fn -> Application.delete_env(:document_compliance_engine, :agent_callback_fun) end)
    :ok
  end

  # Matches `AgentFakes.contract/1`/`w9/1`'s fake extracted values verbatim
  # — required now that the reactor's groundedness check (see checks.ex)
  # halts any run whose extracted fields don't appear in these documents.
  @contract_text "Contract with Acme Corp. Payment Terms: Net 30. Liability: Standard."
  @w9_text "Form W-9. Name of entity: Acme Corp. EIN: 12-3456789."

  defp write_documents(context) do
    dir = System.tmp_dir!() |> Path.join("agent_run_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    contract_path = Path.join(dir, "contract.pdf")
    w9_path = Path.join(dir, "w9.pdf")
    File.write!(contract_path, @contract_text)
    File.write!(w9_path, @w9_text)
    on_exit(fn -> File.rm_rf!(dir) end)

    Map.put(context, :document_paths, %{"contract" => contract_path, "w9" => w9_path})
  end

  setup :write_documents

  defp trigger(document_job_id, paths),
    do: Run.trigger(document_job_id, @document_type_slug, paths)

  test "sends an approved callback when everything checks out", %{document_paths: paths} do
    stub_defaults()

    trigger(7, paths)

    assert_received {:callback, payload}
    assert payload["document_job_id"] == 7
    assert payload["status"] == "approved"
    assert payload["company_name"] == "Acme Corp"
    assert payload["tax_id"] == "12-3456789"
  end

  test "reports confidence + source_quote for non-PII fields, but never for Tax ID", %{
    document_paths: paths
  } do
    stub_defaults(
      extract: fn
        "contract", _schema, _text ->
          {:ok, contract(), %{company_name: %{confidence: 0.9, source_quote: "Acme Corp"}}}

        "w9", _schema, _text ->
          # The fake deliberately DOES supply tax_id metadata here — with a
          # real source_quote containing the raw Tax ID — so this test
          # proves the exclusion actively strips it, not that it merely
          # happens to be absent.
          {:ok, w9(),
           %{
             company_name: %{confidence: 0.85, source_quote: "Acme Corp"},
             tax_id: %{confidence: 1.0, source_quote: "12-3456789"}
           }}
      end
    )

    trigger(20, paths)

    assert_received {:callback, payload}
    assert payload["status"] == "approved"

    assert payload["extraction_metadata"]["contract"]["company_name"] == %{
             "confidence" => 0.9,
             "source_quote" => "Acme Corp"
           }

    assert payload["extraction_metadata"]["w9"]["company_name"] == %{
             "confidence" => 0.85,
             "source_quote" => "Acme Corp"
           }

    # The Tax ID's own confidence/source_quote must never reach this
    # (unencrypted) column — see `Agent.Run.stringify_metadata/1`.
    refute Map.has_key?(payload["extraction_metadata"]["w9"], "tax_id")
    refute inspect(payload["extraction_metadata"]) =~ "12-3456789"
  end

  test "routes a %PDF- prefixed document through pdf_to_text before extraction", %{
    document_paths: paths
  } do
    contract_path = paths["contract"]
    contract_pdf_bytes = "%PDF-1.4\nnot real PDF bytes, just needs the magic header"
    File.write!(contract_path, contract_pdf_bytes)
    test_pid = self()

    stub_defaults(
      pdf_to_text_fun: fn bytes ->
        if bytes == contract_pdf_bytes,
          do: {:ok, "pdftotext output: " <> @contract_text},
          else: {:ok, @w9_text}
      end,
      extract: fn
        "contract", _schema, text ->
          # Task.async_stream (in Extraction.extract_all/2) runs this in a
          # separate process — self() here isn't the test process.
          send(test_pid, {:contract_text_seen, text})
          {:ok, contract()}

        role, schema, text ->
          extract(role, schema, text)
      end
    )

    trigger(19, paths)

    assert_received {:contract_text_seen, "pdftotext output: " <> _}
    assert_received {:callback, payload}
    assert payload["status"] == "approved"
  end

  test "sends needs_review with a thread_id and persists a checkpoint on a mismatch", %{
    document_paths: paths
  } do
    stub_defaults(
      extract: fn
        "w9", _schema, _text -> {:ok, w9(%{company_name: "Totally Different LLC"})}
        role, schema, text -> extract(role, schema, text)
      end
    )

    trigger(9, paths)

    assert_received {:callback, payload}
    assert payload["status"] == "needs_review"
    assert payload["thread_id"] == "document_job-9"
    assert payload["w9_company_name"] == "Totally Different LLC"
    assert payload["explanation"] =~ "Entity name mismatch"

    assert {:ok, checkpoint} = Repository.get_by_thread_id("document_job-9")
    assert checkpoint.document_job_id == 9
    assert checkpoint.status == :awaiting_review
    assert checkpoint.inputs["documents"]["contract"] == @contract_text
  end

  test "truncates a long halt explanation so it fits agent_runs.explanation's varchar(255)", %{
    document_paths: paths
  } do
    long_explanation =
      "The validation of the document job revealed " <> String.duplicate("x", 300)

    stub_defaults(
      extract: fn
        "w9", _schema, _text -> {:ok, w9(%{company_name: "Totally Different LLC"})}
        role, schema, text -> extract(role, schema, text)
      end,
      draft_explanation: fn _findings -> long_explanation end
    )

    trigger(21, paths)

    assert_received {:callback, payload}
    assert payload["status"] == "needs_review"
    assert byte_size(payload["explanation"]) <= 255

    # The full, untruncated explanation is still what gets checkpointed —
    # only the copy written to agent_runs' varchar(255) column is trimmed.
    assert {:ok, checkpoint} = Repository.get_by_thread_id("document_job-21")
    assert checkpoint.explanation == long_explanation
  end

  test "a second halt for the same document_job supersedes a stale, unresolved checkpoint", %{
    document_paths: paths
  } do
    stub_defaults(
      extract: fn
        "w9", _schema, _text -> {:ok, w9(%{company_name: "Totally Different LLC"})}
        role, schema, text -> extract(role, schema, text)
      end
    )

    # Simulates an earlier attempt that halted and checkpointed but was
    # never resumed (e.g. the process was killed before review happened) —
    # thread_id is deterministic per document_job_id, so a fresh run for
    # the same document_job reuses it.
    trigger(22, paths)
    assert_received {:callback, _first_halt}
    assert {:ok, stale_checkpoint} = Repository.get_by_thread_id("document_job-22")

    trigger(22, paths)

    assert_received {:callback, payload}
    assert payload["status"] == "needs_review"
    assert payload["thread_id"] == "document_job-22"

    assert {:ok, fresh_checkpoint} = Repository.get_by_thread_id("document_job-22")
    assert fresh_checkpoint.id != stale_checkpoint.id
  end

  test "resumes a persisted checkpoint with the human's decision", %{document_paths: paths} do
    stub_defaults(
      extract: fn
        "w9", _schema, _text -> {:ok, w9(%{company_name: "Totally Different LLC"})}
        role, schema, text -> extract(role, schema, text)
      end
    )

    trigger(11, paths)
    assert_received {:callback, _needs_review}

    Run.resume(11, "document_job-11", "rejected")

    assert_received {:callback, payload}
    assert payload["status"] == "rejected"
    assert payload["document_job_id"] == 11

    assert {:ok, checkpoint} = Repository.get_by_thread_id("document_job-11")
    assert checkpoint.status == :resumed
  end

  test "sends a failed callback when a document is missing" do
    stub_defaults()

    trigger(12, %{"contract" => "/no/such/file.pdf", "w9" => "/no/such/w9.pdf"})

    assert_received {:callback, payload}
    assert payload["status"] == "failed"
    assert payload["document_job_id"] == 12
  end

  test "sends a failed callback when extraction fails", %{document_paths: paths} do
    stub_defaults(
      extract: fn
        "contract", _schema, _text -> {:error, "simulated extraction failure"}
        role, schema, text -> extract(role, schema, text)
      end
    )

    trigger(13, paths)

    assert_received {:callback, payload}
    assert payload["status"] == "failed"
    assert payload["explanation"] =~ "simulated extraction failure"
  end

  test "truncates a long failure reason so it fits agent_runs.explanation's varchar(255)", %{
    document_paths: paths
  } do
    # A real Reactor.Error.Invalid struct inspects far past 255 chars —
    # writing it verbatim overflows the column and crashes the callback.
    long_reason = %{very_long: String.duplicate("x", 1000)}

    stub_defaults(
      extract: fn
        "contract", _schema, _text -> {:error, long_reason}
        role, schema, text -> extract(role, schema, text)
      end
    )

    trigger(16, paths)

    assert_received {:callback, payload}
    assert payload["status"] == "failed"
    assert byte_size(payload["explanation"]) <= 255
    assert payload["explanation"] =~ "Agent run failed:"
  end

  test "sends a failed callback when resuming an unknown thread" do
    stub_defaults()

    Run.resume(14, "document_job-does-not-exist", "approved")

    assert_received {:callback, payload}
    assert payload["status"] == "failed"
  end

  test "still reports :ok when the callback function itself errors" do
    stub_defaults()

    Application.put_env(:document_compliance_engine, :agent_callback_fun, fn _payload ->
      {:error, :changeset_invalid}
    end)

    assert :ok = trigger(15, %{"contract" => "/no/such/file.pdf", "w9" => "/no/such/w9.pdf"})
  end
end
