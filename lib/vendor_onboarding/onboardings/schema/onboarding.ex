defmodule VendorOnboarding.Onboardings.Schema.Onboarding do
  @moduledoc """
  The ingestion record: what came in, and the onboarding's current
  aggregate status. Extracted/validated fields from an agent run live on
  `VendorOnboarding.AgentRuns.Schema.AgentRun`, not here — this schema
  doesn't know anything about the agent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:received, :processing, :needs_review, :approved, :rejected]

  schema "onboardings" do
    field :status, Ecto.Enum, values: @statuses, default: :received
    field :idempotency_key, :string
    field :document_paths, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          status: :received | :processing | :needs_review | :approved | :rejected,
          idempotency_key: String.t() | nil,
          document_paths: %{optional(String.t()) => String.t()},
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Changeset for creating a row from an ingested webhook payload."
  def ingest_changeset(onboarding, attrs) do
    onboarding
    |> cast(attrs, [:idempotency_key, :document_paths])
    |> validate_required([:idempotency_key, :document_paths])
    |> unique_constraint(:idempotency_key)
  end

  @doc "Changeset for updating just the aggregate status."
  def status_changeset(onboarding, status) do
    change(onboarding, status: status)
  end
end
