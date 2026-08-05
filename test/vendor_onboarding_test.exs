defmodule VendorOnboardingTest do
  use VendorOnboarding.DataCase, async: true

  alias VendorOnboarding.Repository

  test "get_onboarding/1 delegates to the repository" do
    {:ok, onboarding} =
      Repository.insert(%{idempotency_key: "ctx-1", document_paths: %{}})

    assert {:ok, found} = VendorOnboarding.get_onboarding(onboarding.id)
    assert found.id == onboarding.id
    assert VendorOnboarding.get_onboarding(-1) == {:error, :not_found}
  end

  test "list_onboardings/1 delegates to the repository" do
    {:ok, _onboarding} =
      Repository.insert(%{idempotency_key: "ctx-2", document_paths: %{}})

    assert [_ | _] = VendorOnboarding.list_onboardings()
  end
end
