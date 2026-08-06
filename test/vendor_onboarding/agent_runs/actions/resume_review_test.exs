defmodule VendorOnboarding.AgentRuns.Actions.ResumeReviewTest do
  use VendorOnboarding.DataCase, async: true

  alias VendorOnboarding.AgentRuns
  alias VendorOnboarding.AgentRuns.AgentService
  alias VendorOnboarding.Onboardings

  defp needs_review_onboarding(key) do
    {:ok, onboarding} =
      Onboardings.Repository.insert(%{idempotency_key: key, document_paths: %{}})

    {:ok, run} =
      AgentRuns.Repository.insert(%{vendor_onboarding_id: onboarding.id, status: :processing})

    {:ok, _run} =
      AgentRuns.Repository.update_result(run, %{
        status: :needs_review,
        thread_id: "thread-#{onboarding.id}"
      })

    {:ok, onboarding} = Onboardings.update_status(onboarding.id, :needs_review)
    onboarding
  end

  test "calls AgentService.resume/1 with the run's thread_id on a :needs_review onboarding" do
    onboarding = needs_review_onboarding("resume-1")

    Req.Test.stub(AgentService, fn conn ->
      assert {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "onboarding_id" => onboarding.id,
               "thread_id" => "thread-#{onboarding.id}",
               "decision" => "approved"
             }

      Req.Test.json(conn, %{"accepted" => true})
    end)

    assert {:ok, returned} = AgentRuns.resume_review(onboarding.id, :approved)
    assert returned.id == onboarding.id
  end

  test "rejects resuming an onboarding that isn't :needs_review" do
    {:ok, received} =
      Onboardings.Repository.insert(%{idempotency_key: "resume-2", document_paths: %{}})

    assert {:error, :not_awaiting_review} = AgentRuns.resume_review(received.id, :approved)
  end

  test "returns {:error, :not_found} for a missing onboarding" do
    assert {:error, :not_found} = AgentRuns.resume_review(-1, :approved)
  end
end
