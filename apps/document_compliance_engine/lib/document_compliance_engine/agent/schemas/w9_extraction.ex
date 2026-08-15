defmodule DocumentComplianceEngine.Agent.Schemas.W9Extraction do
  @moduledoc """
  Agent 1's extraction from the W-9 only. Kept separate from the contract
  extraction so Agent 2 can cross-check entities between the two documents
  (the headline name-mismatch HITL scenario).
  """

  use Ecto.Schema
  use Instructor

  @llm_doc """
  ## Field Descriptions:
  - company_name: Vendor's legal company name as it appears on the W-9
  - tax_id: Vendor's Tax ID / EIN, verbatim as it appears on the W-9
  """
  @primary_key false
  embedded_schema do
    field(:company_name, :string)
    field(:tax_id, :string)
  end

  @type t :: %__MODULE__{
          company_name: String.t() | nil,
          tax_id: String.t() | nil
        }

  @impl true
  def validate_changeset(changeset) do
    Ecto.Changeset.validate_required(changeset, [:company_name, :tax_id])
  end
end
