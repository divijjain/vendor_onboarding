defmodule DocumentComplianceEngine.Agent.Schemas.EntityMatchResult do
  @moduledoc """
  Agent 2's judgment on whether the contract and W-9 company names refer to
  the same legal entity. An LLM call, not string equality — a formatting
  difference ("Acme Corp" vs "Acme Corporation") must not be flagged as a
  mismatch (see CONTEXT.md's false-positive eval bucket).
  """

  use Ecto.Schema
  use Instructor

  @llm_doc """
  ## Field Descriptions:
  - match: Whether the contract and W-9 company names refer to the same legal entity
  - explanation: Brief explanation grounded in the two names compared
  """
  @primary_key false
  embedded_schema do
    field(:match, :boolean)
    field(:explanation, :string)
  end

  @type t :: %__MODULE__{
          match: boolean() | nil,
          explanation: String.t() | nil
        }

  @impl true
  def validate_changeset(changeset) do
    Ecto.Changeset.validate_required(changeset, [:match, :explanation])
  end
end
