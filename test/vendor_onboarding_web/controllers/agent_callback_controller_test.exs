defmodule VendorOnboardingWeb.AgentCallbackControllerTest do
  use VendorOnboardingWeb.ConnCase, async: true

  alias VendorOnboarding.Repository

  test "POST /webhooks/agent_callback updates status and returns 200", %{conn: conn} do
    {:ok, onboarding} = Repository.insert(%{idempotency_key: "cb-ctrl-1", document_paths: %{}})

    conn =
      post(conn, ~p"/webhooks/agent_callback", %{
        "onboarding_id" => onboarding.id,
        "status" => "approved"
      })

    assert %{"id" => id, "status" => "approved"} = json_response(conn, 200)
    assert id == onboarding.id
  end

  test "POST /webhooks/agent_callback returns 404 for an unknown onboarding_id", %{conn: conn} do
    conn =
      post(conn, ~p"/webhooks/agent_callback", %{"onboarding_id" => -1, "status" => "approved"})

    assert json_response(conn, 404) == %{"error" => "not_found"}
  end
end
