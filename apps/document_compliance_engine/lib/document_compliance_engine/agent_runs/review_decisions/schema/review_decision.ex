defmodule DocumentComplianceEngine.AgentRuns.ReviewDecisions.Schema.ReviewDecision do
  @moduledoc """
  An immutable audit record of a human's approve/reject decision on a
  paused agent run — who decided, what evidence they had in front of them,
  and why. `updated_at` is deliberately absent: nothing about this row is
  meant to change after it's written.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @decisions [:approved, :rejected]

  schema "review_decisions" do
    field :document_job_id, :integer
    field :thread_id, :string
    field :decision, Ecto.Enum, values: @decisions
    field :reviewer, :string
    field :rationale, :string
    field :evidence, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          document_job_id: pos_integer() | nil,
          thread_id: String.t() | nil,
          decision: :approved | :rejected | nil,
          reviewer: String.t() | nil,
          rationale: String.t() | nil,
          evidence: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @doc "Changeset for recording a review decision. No update changeset exists — append-only."
  def create_changeset(review_decision, attrs) do
    review_decision
    |> cast(attrs, [:document_job_id, :thread_id, :decision, :reviewer, :rationale, :evidence])
    |> validate_required([:document_job_id, :thread_id, :decision, :reviewer, :rationale])
  end
end
