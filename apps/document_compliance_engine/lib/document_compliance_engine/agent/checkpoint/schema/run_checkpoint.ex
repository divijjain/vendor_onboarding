defmodule DocumentComplianceEngine.Agent.Checkpoint.Schema.RunCheckpoint do
  @moduledoc """
  A paused run: the serialized halted reactor plus everything needed to
  resume it. Replaces LangGraph's Postgres checkpointer — this row is what
  makes a human-review pause survive a service restart.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "agent_checkpoints"
  @statuses [:awaiting_review, :resumed]

  schema "run_checkpoints" do
    field(:thread_id, :string)
    field(:document_job_id, :integer)
    field(:reactor_state, :binary)
    field(:inputs, :map, default: %{})
    field(:explanation, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :awaiting_review)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          thread_id: String.t() | nil,
          document_job_id: pos_integer() | nil,
          reactor_state: binary() | nil,
          inputs: %{optional(String.t()) => String.t()},
          explanation: String.t() | nil,
          status: :awaiting_review | :resumed,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Changeset for persisting a newly halted run."
  def create_changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [:thread_id, :document_job_id, :reactor_state, :inputs, :explanation, :status])
    |> validate_required([:thread_id, :document_job_id, :reactor_state, :inputs])
    |> unique_constraint(:thread_id)
  end

  @doc "Changeset for marking a checkpoint resumed."
  def status_changeset(checkpoint, status) do
    change(checkpoint, status: status)
  end
end
