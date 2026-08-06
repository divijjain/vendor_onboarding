defmodule VendorOnboarding.OnboardingsTest do
  use VendorOnboarding.DataCase, async: true

  alias VendorOnboarding.Onboardings

  test "get_onboarding/1 delegates to the repository" do
    {:ok, onboarding} =
      Onboardings.Repository.insert(%{idempotency_key: "ctx-1", document_paths: %{}})

    assert {:ok, found} = Onboardings.get_onboarding(onboarding.id)
    assert found.id == onboarding.id
    assert Onboardings.get_onboarding(-1) == {:error, :not_found}
  end

  test "list_onboardings/1 delegates to the repository" do
    {:ok, _onboarding} =
      Onboardings.Repository.insert(%{idempotency_key: "ctx-2", document_paths: %{}})

    assert [_ | _] = Onboardings.list_onboardings()
  end
end
