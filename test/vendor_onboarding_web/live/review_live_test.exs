defmodule VendorOnboardingWeb.ReviewLiveTest do
  use VendorOnboardingWeb.ConnCase, async: true

  alias VendorOnboarding.Repository

  defp needs_review_onboarding do
    {:ok, onboarding} =
      Repository.insert(%{
        idempotency_key: "review-#{System.unique_integer([:positive])}",
        document_paths: %{}
      })

    Repository.update_agent_result(onboarding, %{
      status: :needs_review,
      thread_id: "onboarding-#{onboarding.id}",
      company_name: "Acme Corp",
      w9_company_name: "Totally Different LLC",
      tax_id: "12-3456789",
      payment_terms: "Net 30",
      liability_clauses: "Standard.",
      explanation: "Names do not match."
    })
  end

  test "shows the side-by-side contract/W-9 diff and the drafted explanation", %{conn: conn} do
    {:ok, onboarding} = needs_review_onboarding()

    {:ok, _view, html} = live(conn, ~p"/onboardings/#{onboarding.id}")

    assert html =~ "Acme Corp"
    assert html =~ "Totally Different LLC"
    assert html =~ "12-3456789"
    assert html =~ "Names do not match."
    assert html =~ "Approve"
    assert html =~ "Reject"
  end

  test "approve calls resume_review and shows a flash", %{conn: conn} do
    {:ok, onboarding} = needs_review_onboarding()

    Req.Test.stub(VendorOnboarding.AgentService, fn conn ->
      Req.Test.json(conn, %{"accepted" => true})
    end)

    {:ok, view, _html} = live(conn, ~p"/onboardings/#{onboarding.id}")

    html = view |> element("button", "Approve") |> render_click()
    assert html =~ "waiting for the agent to resume"
  end

  test "shows an error flash when the agent service call fails", %{conn: conn} do
    {:ok, onboarding} = needs_review_onboarding()

    Req.Test.stub(VendorOnboarding.AgentService, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    {:ok, view, _html} = live(conn, ~p"/onboardings/#{onboarding.id}")

    html = view |> element("button", "Reject") |> render_click()
    assert html =~ "Could not submit decision"
  end

  test "hides approve/reject once no longer awaiting review", %{conn: conn} do
    {:ok, onboarding} =
      Repository.insert(%{idempotency_key: "review-approved", document_paths: %{}})

    {:ok, onboarding} = Repository.update_agent_result(onboarding, %{status: :approved})

    {:ok, _view, html} = live(conn, ~p"/onboardings/#{onboarding.id}")

    refute html =~ "Approve"
    assert html =~ "no longer awaiting review"
  end
end
