defmodule DocumentComplianceEngine.DocumentJobs.Actions.IngestWebhookTest do
  use DocumentComplianceEngine.DataCase, async: true
  use Oban.Testing, repo: DocumentComplianceEngine.Repo

  alias DocumentComplianceEngine.Accounts
  alias DocumentComplianceEngine.AgentRuns.Workers.TriggerAgentRunWorker
  alias DocumentComplianceEngine.DocumentJobs

  defp unique_bytes(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp unique_email, do: "ingest-#{System.unique_integer([:positive])}@example.com"

  defp payload(document_type_slug, documents, owner_email \\ nil) do
    Jason.encode!(%{
      "document_type_slug" => document_type_slug,
      "documents" => Map.new(documents, fn {role, bytes} -> {role, Base.encode64(bytes)} end),
      "owner_email" => owner_email || unique_email()
    })
  end

  defp contract_w9_payload(contract, w9) do
    payload("vendor_contract_w9", %{"contract" => contract, "w9" => w9})
  end

  test "creates a :received row, stores documents, and enqueues the agent run job" do
    contract = unique_bytes("contract")
    w9 = unique_bytes("w9")

    assert {:ok, document_job} = DocumentJobs.ingest_webhook(contract_w9_payload(contract, w9))
    assert document_job.status == :received
    assert document_job.document_type_slug == "vendor_contract_w9"
    assert %{"contract" => contract_path, "w9" => w9_path} = document_job.document_paths
    assert File.read!(contract_path) == contract
    assert File.read!(w9_path) == w9

    assert_enqueued(worker: TriggerAgentRunWorker, args: %{document_job_id: document_job.id})

    on_exit(fn ->
      contract_path |> Path.dirname() |> File.rm_rf()
    end)
  end

  test "accepts a different, genuinely smaller document type (invoice: one document)" do
    invoice = unique_bytes("invoice")

    assert {:ok, document_job} =
             DocumentJobs.ingest_webhook(payload("invoice", %{"invoice" => invoice}))

    assert document_job.document_type_slug == "invoice"
    assert %{"invoice" => invoice_path} = document_job.document_paths
    assert File.read!(invoice_path) == invoice

    on_exit(fn ->
      invoice_path |> Path.dirname() |> File.rm_rf()
    end)
  end

  test "rejects a duplicate payload without creating a second row" do
    raw_payload = contract_w9_payload(unique_bytes("contract"), unique_bytes("w9"))

    assert {:ok, document_job} = DocumentJobs.ingest_webhook(raw_payload)
    assert {:error, :duplicate} = DocumentJobs.ingest_webhook(raw_payload)

    assert {:ok, found} = DocumentJobs.get_document_job(document_job.id)
    assert found.id == document_job.id

    on_exit(fn ->
      document_job.document_paths["contract"] |> Path.dirname() |> File.rm_rf()
    end)
  end

  test "rejects malformed JSON as :invalid_payload" do
    assert {:error, :invalid_payload} = DocumentJobs.ingest_webhook("not json")
  end

  test "rejects JSON missing document_type_slug/documents/owner_email as :invalid_payload" do
    assert {:error, :invalid_payload} = DocumentJobs.ingest_webhook(Jason.encode!(%{}))

    assert {:error, :invalid_payload} =
             DocumentJobs.ingest_webhook(
               Jason.encode!(%{
                 "document_type_slug" => "invoice",
                 "documents" => %{"invoice" => "x"}
               })
             )
  end

  test "rejects an unknown document_type_slug" do
    assert {:error, :unknown_document_type} =
             DocumentJobs.ingest_webhook(payload("not_a_real_type", %{"invoice" => "x"}))
  end

  test "rejects documents whose keys don't match the document type's expected roles" do
    assert {:error, :invalid_payload} =
             DocumentJobs.ingest_webhook(payload("vendor_contract_w9", %{"contract" => "only"}))
  end

  test "auto-provisions a user by owner_email, reusing the same account on a repeat email" do
    email = unique_email()

    assert {:ok, first} =
             DocumentJobs.ingest_webhook(
               payload("invoice", %{"invoice" => unique_bytes("invoice")}, email)
             )

    assert {:ok, second} =
             DocumentJobs.ingest_webhook(
               payload("invoice", %{"invoice" => unique_bytes("invoice")}, email)
             )

    assert first.owner_user_id == second.owner_user_id
    assert {:ok, user} = Accounts.get_or_create_user_by_email(email)
    assert user.id == first.owner_user_id

    on_exit(fn ->
      first.document_paths["invoice"] |> Path.dirname() |> File.rm_rf()
      second.document_paths["invoice"] |> Path.dirname() |> File.rm_rf()
    end)
  end
end
