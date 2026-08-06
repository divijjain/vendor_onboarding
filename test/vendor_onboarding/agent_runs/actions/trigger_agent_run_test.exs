defmodule VendorOnboarding.AgentRuns.Actions.TriggerAgentRunTest do
  use VendorOnboarding.DataCase, async: true

  alias VendorOnboarding.AgentRuns
  alias VendorOnboarding.AgentRuns.AgentService
  alias VendorOnboarding.Onboardings

  defp insert_onboarding(key) do
    {:ok, onboarding} =
      Onboardings.Repository.insert(%{idempotency_key: key, document_paths: %{"contract" => "x"}})

    onboarding
  end

  test "starts a run, calls the agent service, and marks the onboarding :processing" do
    onboarding = insert_onboarding("trigger-1")

    Req.Test.stub(AgentService, fn conn ->
      Req.Test.json(conn, %{"accepted" => true})
    end)

    assert {:ok, agent_run} = AgentRuns.trigger_agent_run(onboarding.id)
    assert agent_run.status == :processing
    assert agent_run.vendor_onboarding_id == onboarding.id

    assert {:ok, updated_onboarding} = Onboardings.get_onboarding(onboarding.id)
    assert updated_onboarding.status == :processing
  end

  test "returns an error without starting a run when the agent service call fails" do
    onboarding = insert_onboarding("trigger-2")

    Req.Test.stub(AgentService, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, {:unexpected_status, 500, "boom"}} =
             AgentRuns.trigger_agent_run(onboarding.id)

    assert {:ok, unchanged} = Onboardings.get_onboarding(onboarding.id)
    assert unchanged.status == :received
  end

  test "returns {:error, :not_found} for a missing onboarding" do
    assert {:error, :not_found} = AgentRuns.trigger_agent_run(-1)
  end
end
