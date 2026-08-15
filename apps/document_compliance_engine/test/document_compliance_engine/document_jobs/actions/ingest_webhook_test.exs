defmodule DocumentComplianceEngine.DocumentJobs.Actions.IngestWebhookTest do
  use DocumentComplianceEngine.DataCase, async: true
  use Oban.Testing, repo: DocumentComplianceEngine.Repo

  alias DocumentComplianceEngine.AgentRuns.Workers.TriggerAgentRunWorker
  alias DocumentComplianceEngine.DocumentJobs

  defp unique_bytes(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp payload(contract, w9) do
    Jason.encode!(%{
      "contract" => Base.encode64(contract),
      "w9" => Base.encode64(w9)
    })
  end

  test "creates a :received row, stores documents, and enqueues the agent run job" do
    contract = unique_bytes("contract")
    w9 = unique_bytes("w9")

    assert {:ok, document_job} = DocumentJobs.ingest_webhook(payload(contract, w9))
    assert document_job.status == :received
    assert %{"contract" => contract_path, "w9" => w9_path} = document_job.document_paths
    assert File.read!(contract_path) == contract
    assert File.read!(w9_path) == w9

    assert_enqueued(worker: TriggerAgentRunWorker, args: %{document_job_id: document_job.id})

    on_exit(fn ->
      contract_path |> Path.dirname() |> File.rm_rf()
    end)
  end

  test "rejects a duplicate payload without creating a second row" do
    raw_payload = payload(unique_bytes("contract"), unique_bytes("w9"))

    assert {:ok, document_job} = DocumentJobs.ingest_webhook(raw_payload)
    assert {:error, :duplicate} = DocumentJobs.ingest_webhook(raw_payload)

    assert [found] = DocumentJobs.list_document_jobs()
    assert found.id == document_job.id

    on_exit(fn ->
      document_job.document_paths["contract"] |> Path.dirname() |> File.rm_rf()
    end)
  end

  test "rejects malformed JSON as :invalid_payload" do
    assert {:error, :invalid_payload} = DocumentJobs.ingest_webhook("not json")
  end

  test "rejects JSON missing the contract/w9 fields as :invalid_payload" do
    assert {:error, :invalid_payload} = DocumentJobs.ingest_webhook(Jason.encode!(%{}))
  end
end
