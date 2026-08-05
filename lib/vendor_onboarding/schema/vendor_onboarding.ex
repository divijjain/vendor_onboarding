defmodule VendorOnboarding.Schema.VendorOnboarding do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:received, :processing, :needs_review, :approved, :rejected]

  schema "vendor_onboardings" do
    field :status, Ecto.Enum, values: @statuses, default: :received
    field :thread_id, :string
    field :idempotency_key, :string

    field :company_name, :string
    field :tax_id, VendorOnboarding.Encrypted.Binary
    field :payment_terms, :string
    field :liability_clauses, :string

    field :document_paths, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a row from an ingested webhook payload."
  def ingest_changeset(onboarding, attrs) do
    onboarding
    |> cast(attrs, [:idempotency_key, :document_paths])
    |> validate_required([:idempotency_key, :document_paths])
    |> unique_constraint(:idempotency_key)
  end

  @doc "Changeset for writing back an agent run's extracted fields and status."
  def agent_result_changeset(onboarding, attrs) do
    onboarding
    |> cast(attrs, [
      :status,
      :thread_id,
      :company_name,
      :tax_id,
      :payment_terms,
      :liability_clauses
    ])
    |> validate_required([:status])
  end
end
