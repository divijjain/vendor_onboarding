defmodule VendorOnboarding.Actions.TriggerAgentRunTest do
  use VendorOnboarding.DataCase, async: true

  alias VendorOnboarding.Repository

  test "marks the row :processing after a successful trigger" do
    {:ok, onboarding} =
      Repository.insert(%{idempotency_key: "trigger-1", document_paths: %{"contract" => "x"}})

    Req.Test.stub(VendorOnboarding.AgentService, fn conn ->
      Req.Test.json(conn, %{"accepted" => true})
    end)

    assert {:ok, updated} = VendorOnboarding.trigger_agent_run(onboarding.id)
    assert updated.status == :processing
  end

  test "returns an error without changing status when the agent service call fails" do
    {:ok, onboarding} = Repository.insert(%{idempotency_key: "trigger-2", document_paths: %{}})

    Req.Test.stub(VendorOnboarding.AgentService, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, {:unexpected_status, 500, "boom"}} =
             VendorOnboarding.trigger_agent_run(onboarding.id)

    assert {:ok, unchanged} = Repository.get(onboarding.id)
    assert unchanged.status == :received
  end

  test "returns {:error, :not_found} for a missing onboarding" do
    assert {:error, :not_found} = VendorOnboarding.trigger_agent_run(-1)
  end
end
