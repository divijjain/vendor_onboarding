defmodule DocumentComplianceEngine.Repo do
  use Ecto.Repo,
    otp_app: :document_compliance_engine,
    adapter: Ecto.Adapters.Postgres
end
