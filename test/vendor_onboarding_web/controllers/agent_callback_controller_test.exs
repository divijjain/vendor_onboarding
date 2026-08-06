defmodule VendorOnboardingWeb.AgentCallbackControllerTest do
  use VendorOnboardingWeb.ConnCase, async: true

  alias VendorOnboarding.AgentRuns
  alias VendorOnboarding.Onboardings

  test "POST /webhooks/agent_callback updates status and returns 200", %{conn: conn} do
    {:ok, onboarding} =
      Onboardings.Repository.insert(%{idempotency_key: "cb-ctrl-1", document_paths: %{}})

    {:ok, _run} =
      AgentRuns.Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :processing})

    conn =
      post(conn, ~p"/webhooks/agent_callback", %{
        "onboarding_id" => onboarding.id,
        "status" => "approved"
      })

    assert %{"onboarding_id" => onboarding_id, "status" => "approved"} = json_response(conn, 200)
    assert onboarding_id == onboarding.id
  end

  test "POST /webhooks/agent_callback returns 404 when no run has started for that onboarding_id",
       %{conn: conn} do
    conn =
      post(conn, ~p"/webhooks/agent_callback", %{"onboarding_id" => -1, "status" => "approved"})

    assert json_response(conn, 404) == %{"error" => "not_found"}
  end
end
