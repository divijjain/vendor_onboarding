defmodule VendorOnboarding.AgentRuns.Actions.HandleAgentCallbackTest do
  use VendorOnboarding.DataCase, async: true

  alias VendorOnboarding.AgentRuns
  alias VendorOnboarding.Onboardings

  defp insert_onboarding_with_run(key) do
    {:ok, onboarding} =
      Onboardings.Repository.insert(%{idempotency_key: key, document_paths: %{}})

    {:ok, _run} =
      AgentRuns.Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :processing})

    onboarding
  end

  test "writes back the run's result, mirrors status onto the onboarding, and broadcasts PubSub" do
    onboarding = insert_onboarding_with_run("cb-1")
    onboarding_id = onboarding.id

    Phoenix.PubSub.subscribe(VendorOnboarding.PubSub, "vendor_onboarding")

    assert {:ok, updated_run} =
             AgentRuns.handle_agent_callback(%{
               "onboarding_id" => onboarding.id,
               "status" => "needs_review",
               "thread_id" => "thread-abc",
               "company_name" => "Acme Corp",
               "explanation" => "Names differ."
             })

    assert updated_run.status == :needs_review
    assert updated_run.thread_id == "thread-abc"
    assert updated_run.company_name == "Acme Corp"

    assert {:ok, updated_onboarding} = Onboardings.get_onboarding(onboarding.id)
    assert updated_onboarding.status == :needs_review

    # Other concurrently-running async tests broadcast on this same topic, so
    # pin the id we care about rather than asserting on whatever arrives first.
    assert_received {:status_updated, ^onboarding_id}
  end

  test "accepts a :failed status so a crashed agent run surfaces instead of hanging forever" do
    onboarding = insert_onboarding_with_run("cb-3")

    assert {:ok, updated_run} =
             AgentRuns.handle_agent_callback(%{
               "onboarding_id" => onboarding.id,
               "status" => "failed",
               "explanation" => "Agent run failed: OpenAIError: Missing credentials."
             })

    assert updated_run.status == :failed

    assert {:ok, updated_onboarding} = Onboardings.get_onboarding(onboarding.id)
    assert updated_onboarding.status == :failed
  end

  test "returns {:error, :not_found} when no run has started for that onboarding" do
    {:ok, onboarding} =
      Onboardings.Repository.insert(%{idempotency_key: "cb-2", document_paths: %{}})

    assert {:error, :not_found} =
             AgentRuns.handle_agent_callback(%{
               "onboarding_id" => onboarding.id,
               "status" => "approved"
             })
  end
end
