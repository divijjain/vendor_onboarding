defmodule DocumentComplianceEngine.DocumentJobs.Actions.ReadDocumentsTest do
  use DocumentComplianceEngine.DataCase, async: true

  alias DocumentComplianceEngine.DocumentJobs

  defp unique_bytes(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp payload(documents) do
    Jason.encode!(%{
      "document_type_slug" => "vendor_contract_w9",
      "documents" => Map.new(documents, fn {role, bytes} -> {role, Base.encode64(bytes)} end)
    })
  end

  test "reads every stored document back, sorted by role" do
    contract = unique_bytes("contract")
    w9 = unique_bytes("w9")

    {:ok, document_job} =
      DocumentJobs.ingest_webhook(payload(%{"contract" => contract, "w9" => w9}))

    on_exit(fn ->
      document_job.document_paths["contract"] |> Path.dirname() |> File.rm_rf()
    end)

    assert DocumentJobs.read_documents(document_job) == [{"contract", contract}, {"w9", w9}]
  end

  test "skips a role whose file can't be read instead of failing" do
    document_job = %DocumentComplianceEngine.DocumentJobs.Schema.DocumentJob{
      document_paths: %{"contract" => "/nonexistent/path.pdf"}
    }

    assert DocumentJobs.read_documents(document_job) == []
  end

  test "returns an empty list for a document_job with no stored paths" do
    document_job = %DocumentComplianceEngine.DocumentJobs.Schema.DocumentJob{document_paths: %{}}

    assert DocumentJobs.read_documents(document_job) == []
  end
end
