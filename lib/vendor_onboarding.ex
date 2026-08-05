defmodule VendorOnboarding do
  @moduledoc """
  Public API for the vendor onboarding domain. `defdelegate` only — no logic here.
  """

  alias VendorOnboarding.Repository

  defdelegate get_onboarding(id), to: Repository, as: :get
  defdelegate get_onboarding!(id), to: Repository, as: :get!
  defdelegate list_onboardings(opts \\ []), to: Repository, as: :list
end
