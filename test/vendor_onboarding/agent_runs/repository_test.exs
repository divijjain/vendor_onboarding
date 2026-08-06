defmodule VendorOnboarding.AgentRuns.RepositoryTest do
  use VendorOnboarding.DataCase, async: true

  alias VendorOnboarding.AgentRuns.Repository
  alias VendorOnboarding.Onboardings.Repository, as: OnboardingsRepository

  defp insert_onboarding(key) do
    {:ok, onboarding} =
      OnboardingsRepository.insert(%{idempotency_key: key, document_paths: %{}})

    onboarding
  end

  describe "insert/1" do
    test "starts a run with status :processing" do
      onboarding = insert_onboarding("run-1")

      assert {:ok, run} =
               Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :processing})

      assert run.status == :processing
      assert run.vendor_onboarding_id == onboarding.id
    end
  end

  describe "update_result/2" do
    test "writes back status, thread_id, and encrypted tax_id" do
      onboarding = insert_onboarding("run-2")
      {:ok, run} = Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :processing})

      assert {:ok, updated} =
               Repository.update_result(run, %{
                 status: :needs_review,
                 thread_id: "thread-1",
                 company_name: "Acme Corp",
                 w9_company_name: "Acme Corporation",
                 tax_id: "12-3456789",
                 payment_terms: "Net 30",
                 liability_clauses: "Standard indemnification clause.",
                 explanation: "Names differ."
               })

      assert updated.status == :needs_review
      assert updated.thread_id == "thread-1"
      assert updated.tax_id == "12-3456789"
    end

    test "persists tax_id encrypted at rest, not as plaintext" do
      onboarding = insert_onboarding("run-3")
      {:ok, run} = Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :processing})

      {:ok, _updated} = Repository.update_result(run, %{status: :approved, tax_id: "12-3456789"})

      %{rows: [[raw_binary]]} =
        Ecto.Adapters.SQL.query!(
          VendorOnboarding.Repo,
          "SELECT tax_id FROM agent_runs WHERE id = $1",
          [run.id]
        )

      refute raw_binary == "12-3456789"
    end
  end

  describe "get_latest_for_onboarding/1" do
    test "returns the most recently inserted run" do
      onboarding = insert_onboarding("run-4")
      {:ok, _older} = Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :rejected})

      {:ok, newer} =
        Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :processing})

      assert {:ok, found} = Repository.get_latest_for_onboarding(onboarding.id)
      assert found.id == newer.id
    end

    test "returns {:error, :not_found} when no run exists" do
      onboarding = insert_onboarding("run-5")
      assert Repository.get_latest_for_onboarding(onboarding.id) == {:error, :not_found}
    end
  end

  describe "latest_by_onboarding_ids/1" do
    test "batches the latest run per onboarding id" do
      a = insert_onboarding("run-6a")
      b = insert_onboarding("run-6b")

      {:ok, _a_old} = Repository.insert(%{vendor_onboarding_id: a.id, status: :rejected})
      {:ok, a_new} = Repository.insert(%{vendor_onboarding_id: a.id, status: :approved})
      {:ok, b_run} = Repository.insert(%{vendor_onboarding_id: b.id, status: :processing})

      result = Repository.latest_by_onboarding_ids([a.id, b.id])

      assert result[a.id].id == a_new.id
      assert result[b.id].id == b_run.id
    end
  end
end
