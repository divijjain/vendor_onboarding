defmodule VendorOnboarding.DocumentJobs.Schema.DocumentJob do
  @moduledoc """
  The ingestion record: what came in, its document type, and its current
  aggregate status. Extracted/validated fields from an agent run live on
  `VendorOnboarding.AgentRuns.Schema.AgentRun`, not here — this schema
  doesn't know anything about the agent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:received, :processing, :needs_review, :approved, :rejected, :failed]

  # The only document type today's fixed pipeline actually implements —
  # matches the row seeded by the generalize_onboardings_to_document_jobs
  # migration. `IngestWebhook` defaults new jobs onto this slug until
  # ingestion itself is extended to accept a document type per request.
  @default_document_type_slug "vendor_contract_w9"

  schema "document_jobs" do
    field :status, Ecto.Enum, values: @statuses, default: :received
    field :idempotency_key, :string
    field :document_paths, :map, default: %{}
    field :document_type_slug, :string, default: @default_document_type_slug

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          status: :received | :processing | :needs_review | :approved | :rejected | :failed,
          idempotency_key: String.t() | nil,
          document_paths: %{optional(String.t()) => String.t()},
          document_type_slug: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec default_document_type_slug() :: String.t()
  def default_document_type_slug, do: @default_document_type_slug

  @doc "Changeset for creating a row from an ingested webhook payload."
  def ingest_changeset(document_job, attrs) do
    document_job
    |> cast(attrs, [:idempotency_key, :document_paths, :document_type_slug])
    |> validate_required([:idempotency_key, :document_paths, :document_type_slug])
    |> unique_constraint(:idempotency_key)
    |> foreign_key_constraint(:document_type_slug)
  end

  @doc "Changeset for updating just the aggregate status."
  def status_changeset(document_job, status) do
    change(document_job, status: status)
  end
end
