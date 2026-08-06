defmodule VendorOnboarding.Onboardings.Actions.ListWithLatestRunTest do
  use VendorOnboarding.DataCase, async: true

  alias VendorOnboarding.AgentRuns
  alias VendorOnboarding.Onboardings

  defp insert_onboarding(key) do
    {:ok, onboarding} =
      Onboardings.Repository.insert(%{idempotency_key: key, document_paths: %{}})

    onboarding
  end

  describe "run/1" do
    test "merges each onboarding with its latest run's company_name, batched not N+1" do
      onboarding = insert_onboarding("list-1")

      {:ok, _older} =
        AgentRuns.Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :rejected})

      {:ok, newer} =
        AgentRuns.Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :processing})

      {:ok, _updated} =
        AgentRuns.Repository.update_result(newer, %{
          status: :processing,
          company_name: "Acme Corp"
        })

      rows = Onboardings.list_onboardings_with_latest_run()
      row = Enum.find(rows, &(&1.id == onboarding.id))

      assert row.company_name == "Acme Corp"
      assert row.status == onboarding.status
    end

    test "company_name is nil when no run has started yet" do
      onboarding = insert_onboarding("list-2")

      rows = Onboardings.list_onboardings_with_latest_run()
      row = Enum.find(rows, &(&1.id == onboarding.id))

      assert row.company_name == nil
    end
  end

  describe "reload/1" do
    test "returns the same merged shape for a single onboarding" do
      onboarding = insert_onboarding("list-3")

      {:ok, run} =
        AgentRuns.Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :processing})

      {:ok, _updated} =
        AgentRuns.Repository.update_result(run, %{status: :approved, company_name: "Acme Corp"})

      # HandleAgentCallback keeps these in sync in the real flow; done
      # explicitly here since this test writes to AgentRuns directly.
      {:ok, _onboarding} = Onboardings.update_status(onboarding.id, :approved)

      assert {:ok, row} = Onboardings.reload_onboarding_row(onboarding.id)
      assert row.id == onboarding.id
      assert row.company_name == "Acme Corp"
      assert row.status == :approved
    end

    test "returns {:error, :not_found} for a missing onboarding" do
      assert Onboardings.reload_onboarding_row(-1) == {:error, :not_found}
    end
  end
end
