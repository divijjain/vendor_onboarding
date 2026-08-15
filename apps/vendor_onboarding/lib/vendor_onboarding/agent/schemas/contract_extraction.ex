defmodule VendorOnboarding.Agent.Schemas.ContractExtraction do
  @moduledoc """
  Agent 1's extraction from the contract only. Payment terms and liability
  clauses only ever appear in the contract, not the W-9.
  """

  use Ecto.Schema
  use Instructor

  @llm_doc """
  ## Field Descriptions:
  - company_name: Vendor's legal company name as it appears on the contract
  - payment_terms: Payment terms as stated in the contract
  - liability_clauses: Liability/indemnification clauses as stated in the contract
  """
  @primary_key false
  embedded_schema do
    field(:company_name, :string)
    field(:payment_terms, :string)
    field(:liability_clauses, :string)
  end

  @type t :: %__MODULE__{
          company_name: String.t() | nil,
          payment_terms: String.t() | nil,
          liability_clauses: String.t() | nil
        }

  @impl true
  def validate_changeset(changeset) do
    Ecto.Changeset.validate_required(changeset, [
      :company_name,
      :payment_terms,
      :liability_clauses
    ])
  end
end
