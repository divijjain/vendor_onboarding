defmodule VendorOnboarding.Actions.HandleAgentCallbackTest do
  use VendorOnboarding.DataCase, async: true

  alias VendorOnboarding.Repository

  test "writes back status/thread_id/extracted fields and broadcasts PubSub" do
    {:ok, onboarding} = Repository.insert(%{idempotency_key: "cb-1", document_paths: %{}})
    onboarding_id = onboarding.id

    Phoenix.PubSub.subscribe(VendorOnboarding.PubSub, "vendor_onboarding")

    assert {:ok, updated} =
             VendorOnboarding.handle_agent_callback(%{
               "onboarding_id" => onboarding.id,
               "status" => "needs_review",
               "thread_id" => "thread-abc",
               "company_name" => "Acme Corp"
             })

    assert updated.status == :needs_review
    assert updated.thread_id == "thread-abc"
    assert updated.company_name == "Acme Corp"

    # Other concurrently-running async tests broadcast on this same topic, so
    # pin the id we care about rather than asserting on whatever arrives first.
    assert_received {:status_updated, ^onboarding_id}
  end

  test "returns {:error, :not_found} for a missing onboarding" do
    assert {:error, :not_found} =
             VendorOnboarding.handle_agent_callback(%{
               "onboarding_id" => -1,
               "status" => "approved"
             })
  end
end
