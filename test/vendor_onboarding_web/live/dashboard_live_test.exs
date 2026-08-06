defmodule VendorOnboardingWeb.DashboardLiveTest do
  use VendorOnboardingWeb.ConnCase, async: true

  alias VendorOnboarding.AgentRuns
  alias VendorOnboarding.Onboardings

  defp insert_onboarding(key) do
    {:ok, onboarding} =
      Onboardings.Repository.insert(%{idempotency_key: key, document_paths: %{}})

    onboarding
  end

  defp mark_needs_review(onboarding) do
    {:ok, run} =
      AgentRuns.Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :processing})

    {:ok, _run} =
      AgentRuns.Repository.update_result(run, %{status: :needs_review, thread_id: "t-1"})

    {:ok, onboarding} = Onboardings.update_status(onboarding.id, :needs_review)
    onboarding
  end

  test "lists onboardings with a status badge and a review link only when needs_review",
       %{conn: conn} do
    received = insert_onboarding("dash-received")
    needs_review = "dash-needs-review" |> insert_onboarding() |> mark_needs_review()

    {:ok, _view, html} = live(conn, ~p"/onboardings")

    assert html =~ "needs_review"
    assert html =~ ~p"/onboardings/#{needs_review.id}"
    refute html =~ ~p"/onboardings/#{received.id}"
  end

  test "reacts to a PubSub status update by reloading just that row", %{conn: conn} do
    onboarding = insert_onboarding("dash-pubsub")

    {:ok, view, html} = live(conn, ~p"/onboardings")
    assert html =~ "received"
    refute render(view) =~ "approved"

    {:ok, _updated} = Onboardings.update_status(onboarding.id, :approved)

    Phoenix.PubSub.broadcast(
      VendorOnboarding.PubSub,
      "vendor_onboarding",
      {:status_updated, onboarding.id}
    )

    assert render(view) =~ "approved"
  end
end
