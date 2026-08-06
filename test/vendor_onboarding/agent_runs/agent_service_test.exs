defmodule VendorOnboarding.AgentRuns.AgentServiceTest do
  use ExUnit.Case, async: true

  alias VendorOnboarding.AgentRuns.AgentService

  test "trigger/1 returns {:ok, body} on a 2xx response" do
    Req.Test.stub(AgentService, fn conn ->
      Req.Test.json(conn, %{"accepted" => true})
    end)

    assert {:ok, %{"accepted" => true}} =
             AgentService.trigger(%{onboarding_id: 1, document_paths: %{}})
  end

  test "trigger/1 returns {:error, {:unexpected_status, _, _}} on a non-2xx response" do
    Req.Test.stub(AgentService, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, {:unexpected_status, 500, "boom"}} =
             AgentService.trigger(%{onboarding_id: 1, document_paths: %{}})
  end

  test "trigger/1 returns {:error, _} when the connection fails" do
    Req.Test.stub(AgentService, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, %Req.TransportError{}} =
             AgentService.trigger(%{onboarding_id: 1, document_paths: %{}})
  end

  test "resume/1 returns {:ok, body} on a 2xx response" do
    Req.Test.stub(AgentService, fn conn ->
      Req.Test.json(conn, %{"accepted" => true})
    end)

    assert {:ok, %{"accepted" => true}} =
             AgentService.resume(%{
               onboarding_id: 1,
               thread_id: "onboarding-1",
               decision: "approved"
             })
  end
end
