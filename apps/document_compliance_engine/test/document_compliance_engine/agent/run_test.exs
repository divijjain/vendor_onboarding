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

  defp write_documents(context) do
    dir = System.tmp_dir!() |> Path.join("agent_run_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    contract_path = Path.join(dir, "contract.pdf")
    w9_path = Path.join(dir, "w9.pdf")
    File.write!(contract_path, "contract text")
    File.write!(w9_path, "w9 text")
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
    assert checkpoint.inputs["documents"]["contract"] == "contract text"
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
