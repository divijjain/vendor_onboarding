defmodule VendorOnboarding.AgentRuns.Schema.AgentRun do
  @moduledoc """
  One agent run's output for a given document_job. A separate table (not
  columns bolted onto `document_jobs`) so re-runs keep history instead of
  overwriting the previous run's result.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:processing, :needs_review, :approved, :rejected, :failed]

  schema "agent_runs" do
    belongs_to :document_job, VendorOnboarding.DocumentJobs.Schema.DocumentJob

    field :status, Ecto.Enum, values: @statuses, default: :processing
    field :thread_id, :string

    field :company_name, :string
    field :w9_company_name, :string
    field :tax_id, VendorOnboarding.Encrypted.Binary
    field :payment_terms, :string
    field :liability_clauses, :string
    field :explanation, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          document_job_id: pos_integer() | nil,
          status: :processing | :needs_review | :approved | :rejected | :failed,
          thread_id: String.t() | nil,
          company_name: String.t() | nil,
          w9_company_name: String.t() | nil,
          tax_id: String.t() | nil,
          payment_terms: String.t() | nil,
          liability_clauses: String.t() | nil,
          explanation: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Changeset for starting a new run."
  def create_changeset(agent_run, attrs) do
    agent_run
    |> cast(attrs, [:document_job_id, :status])
    |> validate_required([:document_job_id, :status])
  end

  @doc "Changeset for writing back a run's result from the agent callback."
  def result_changeset(agent_run, attrs) do
    agent_run
    |> cast(attrs, [
      :status,
      :thread_id,
      :company_name,
      :w9_company_name,
      :tax_id,
      :payment_terms,
      :liability_clauses,
      :explanation
    ])
    |> validate_required([:status])
  end
end
