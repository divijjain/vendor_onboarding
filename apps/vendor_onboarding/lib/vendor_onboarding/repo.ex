defmodule VendorOnboarding.Repo do
  use Ecto.Repo,
    otp_app: :vendor_onboarding,
    adapter: Ecto.Adapters.Postgres
end
