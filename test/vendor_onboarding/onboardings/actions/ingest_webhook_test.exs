defmodule VendorOnboarding.Onboardings.Actions.IngestWebhookTest do
  use VendorOnboarding.DataCase, async: true
  use Oban.Testing, repo: VendorOnboarding.Repo

  alias VendorOnboarding.AgentRuns.Workers.TriggerAgentRunWorker
  alias VendorOnboarding.Onboardings

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

    assert {:ok, onboarding} = Onboardings.ingest_webhook(payload(contract, w9))
    assert onboarding.status == :received
    assert %{"contract" => contract_path, "w9" => w9_path} = onboarding.document_paths
    assert File.read!(contract_path) == contract
    assert File.read!(w9_path) == w9

    assert_enqueued(worker: TriggerAgentRunWorker, args: %{onboarding_id: onboarding.id})

    on_exit(fn ->
      contract_path |> Path.dirname() |> File.rm_rf()
    end)
  end

  test "rejects a duplicate payload without creating a second row" do
    raw_payload = payload(unique_bytes("contract"), unique_bytes("w9"))

    assert {:ok, onboarding} = Onboardings.ingest_webhook(raw_payload)
    assert {:error, :duplicate} = Onboardings.ingest_webhook(raw_payload)

    assert [found] = Onboardings.list_onboardings()
    assert found.id == onboarding.id

    on_exit(fn ->
      onboarding.document_paths["contract"] |> Path.dirname() |> File.rm_rf()
    end)
  end

  test "rejects malformed JSON as :invalid_payload" do
    assert {:error, :invalid_payload} = Onboardings.ingest_webhook("not json")
  end

  test "rejects JSON missing the contract/w9 fields as :invalid_payload" do
    assert {:error, :invalid_payload} = Onboardings.ingest_webhook(Jason.encode!(%{}))
  end
end
