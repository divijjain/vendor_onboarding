defmodule DocumentComplianceEngine.AgentRuns.AuditSamples.Schema.AuditSample do
  @moduledoc """
  A single auto-approved agent run selected for post-hoc human
  spot-checking. Starts `:pending`; a compliance officer later records
  whether the auto-approval held up (`:confirmed`) or was actually
  wrong (`:discrepancy`). Deliberately doesn't touch `document_jobs` or
  `agent_runs` status either way — this is an out-of-band audit record,
  not a second writer of pipeline state (see `HandleAgentCallback`'s
  moduledoc on single-writer status).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :confirmed, :discrepancy]

  schema "audit_samples" do
    field :document_job_id, :integer
    field :agent_run_id, :integer
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :reviewer, :string
    field :notes, :string
    field :reviewed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          document_job_id: pos_integer() | nil,
          agent_run_id: pos_integer() | nil,
          status: :pending | :confirmed | :discrepancy,
          reviewer: String.t() | nil,
          notes: String.t() | nil,
          reviewed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Changeset for sampling a run for audit."
  def create_changeset(audit_sample, attrs) do
    audit_sample
    |> cast(attrs, [:document_job_id, :agent_run_id, :status])
    |> validate_required([:document_job_id, :agent_run_id, :status])
    |> unique_constraint(:agent_run_id)
  end

  @doc "Changeset for recording a compliance officer's audit outcome."
  def review_changeset(audit_sample, attrs) do
    audit_sample
    |> cast(attrs, [:status, :reviewer, :notes, :reviewed_at])
    |> validate_required([:status, :reviewer, :reviewed_at])
    |> validate_inclusion(:status, [:confirmed, :discrepancy])
  end
end
