defmodule DocumentComplianceEngine.Agent.ValidationResult do
  @moduledoc """
  Agent 2's combined validation output: the result of running every
  `validation_rules` entry configured for the document type against the
  extracted data. `approved?/1` is the decision-branch input.
  """

  @enforce_keys [:checks]
  defstruct [:checks]

  @type check :: %{rule: map(), passed: boolean(), detail: String.t() | nil}

  @type t :: %__MODULE__{checks: [check()]}

  @spec approved?(t()) :: boolean()
  def approved?(%__MODULE__{} = result) do
    Enum.all?(result.checks, & &1.passed)
  end

  @spec failed_checks(t()) :: [check()]
  def failed_checks(%__MODULE__{} = result) do
    Enum.reject(result.checks, & &1.passed)
  end
end
