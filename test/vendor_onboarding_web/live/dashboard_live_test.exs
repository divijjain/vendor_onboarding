defmodule VendorOnboardingWeb.DashboardLiveTest do
  use VendorOnboardingWeb.ConnCase, async: true

  alias VendorOnboarding.Repository

  defp insert_onboarding(key) do
    {:ok, onboarding} = Repository.insert(%{idempotency_key: key, document_paths: %{}})
    onboarding
  end

  test "lists onboardings with a status badge and a review link only when needs_review",
       %{conn: conn} do
    received = insert_onboarding("dash-received")

    needs_review =
      "dash-needs-review"
      |> insert_onboarding()
      |> then(&Repository.update_agent_result(&1, %{status: :needs_review, thread_id: "t-1"}))
      |> then(fn {:ok, onboarding} -> onboarding end)

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

    {:ok, _updated} = Repository.update_agent_result(onboarding, %{status: :approved})

    Phoenix.PubSub.broadcast(
      VendorOnboarding.PubSub,
      "vendor_onboarding",
      {:status_updated, onboarding.id}
    )

    assert render(view) =~ "approved"
  end
end
