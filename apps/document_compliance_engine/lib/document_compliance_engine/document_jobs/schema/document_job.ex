defmodule DocumentComplianceEngine.DocumentJobs.Schema.DocumentJob do
  @moduledoc """
  The ingestion record: what came in, its document type, and its current
  aggregate status. Extracted/validated fields from an agent run live on
  `DocumentComplianceEngine.AgentRuns.Schema.AgentRun`, not here — this schema
  doesn't know anything about the agent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:received, :processing, :needs_review, :approved, :rejected, :failed]

  schema "document_jobs" do
    field :status, Ecto.Enum, values: @statuses, default: :received
    field :idempotency_key, :string
    field :document_paths, :map, default: %{}
    field :document_type_slug, :string
    field :owner_user_id, :integer
    field :organization_id, :integer

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          status: :received | :processing | :needs_review | :approved | :rejected | :failed,
          idempotency_key: String.t() | nil,
          document_paths: %{optional(String.t()) => String.t()},
          document_type_slug: String.t() | nil,
          owner_user_id: pos_integer() | nil,
          organization_id: pos_integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Changeset for creating a row from an ingested webhook payload.
  `organization_id` is deliberately not in `validate_required/2` — it's
  `nil` whenever the resolved owner hasn't joined an organization yet,
  backfilled later by `DocumentJobs.backfill_organization_id_for_owner/2`.
  """
  def ingest_changeset(document_job, attrs) do
    document_job
    |> cast(attrs, [
      :idempotency_key,
      :document_paths,
      :document_type_slug,
      :owner_user_id,
      :organization_id
    ])
    |> validate_required([:idempotency_key, :document_paths, :document_type_slug, :owner_user_id])
    |> unique_constraint(:idempotency_key)
    |> foreign_key_constraint(:document_type_slug)
  end

  @doc "Changeset for updating just the aggregate status."
  def status_changeset(document_job, status) do
    change(document_job, status: status)
  end
end
