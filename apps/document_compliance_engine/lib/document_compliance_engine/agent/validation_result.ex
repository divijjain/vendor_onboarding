defmodule DocumentComplianceEngine.Agent.ValidationResult do
  @moduledoc """
  Agent 2's combined validation output: entity match + the two MCP tool
  calls. `approved?/1` is the decision-branch input.
  """

  alias DocumentComplianceEngine.Agent.Schemas.EntityMatchResult

  @enforce_keys [:entity_match, :tax_id_valid, :sanctions_flagged]
  defstruct [:entity_match, :tax_id_valid, :sanctions_flagged, :sanctions_reason]

  @type t :: %__MODULE__{
          entity_match: EntityMatchResult.t(),
          tax_id_valid: boolean(),
          sanctions_flagged: boolean(),
          sanctions_reason: String.t() | nil
        }

  @spec approved?(t()) :: boolean()
  def approved?(%__MODULE__{} = result) do
    result.entity_match.match and result.tax_id_valid and not result.sanctions_flagged
  end
end
