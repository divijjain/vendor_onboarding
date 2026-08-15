defmodule DocumentComplianceEngine.Agent.Checks do
  @moduledoc """
  Agent 2: the entity-match LLM judgment plus the two MCP tool calls, and
  the drafted explanation used when a run pauses for human review.
  """

  alias DocumentComplianceEngine.Agent.McpClient
  alias DocumentComplianceEngine.Agent.Schemas.EntityMatchResult
  alias DocumentComplianceEngine.Agent.ValidationResult

  @entity_match_prompt """
  Do these two company names refer to the same legal entity? Minor formatting \
  differences (abbreviations, punctuation, "Corp" vs "Corporation") are still a \
  match; a genuinely different vendor name is not.

  Contract name: %{contract_name}
  W-9 name: %{w9_name}
  """

  @explanation_prompt """
  Draft a brief, concrete explanation of the discrepancy found while validating \
  this document job, grounded only in the facts below. Do not invent details.

  %{findings}
  """

  @spec validate(map()) :: {:ok, ValidationResult.t()} | {:error, term()}
  def validate(%{contract: contract, w9: w9}) do
    with {:ok, entity_match} <- entity_match(contract.company_name, w9.company_name),
         {:ok, tax} <- McpClient.validate_tax_id(w9.tax_id),
         {:ok, sanctions} <- McpClient.screen_vendor(contract.company_name) do
      {:ok,
       %ValidationResult{
         entity_match: entity_match,
         tax_id_valid: tax.valid,
         sanctions_flagged: sanctions.flagged,
         sanctions_reason: sanctions.reason
       }}
    end
  end

  @spec entity_match(String.t(), String.t()) :: {:ok, EntityMatchResult.t()} | {:error, term()}
  def entity_match(contract_name, w9_name) do
    case Application.get_env(:document_compliance_engine, :agent_entity_match) do
      nil ->
        content =
          String.replace(@entity_match_prompt, "%{contract_name}", contract_name)
          |> String.replace("%{w9_name}", w9_name)

        Instructor.chat_completion(
          model: "gpt-4o-mini",
          response_model: EntityMatchResult,
          max_retries: 1,
          messages: [%{role: "user", content: content}]
        )

      fun ->
        fun.(contract_name, w9_name)
    end
  end

  @spec draft_explanation(ValidationResult.t()) :: String.t()
  def draft_explanation(%ValidationResult{} = validation) do
    findings = describe_findings(validation)

    case Application.get_env(:document_compliance_engine, :agent_draft_explanation) do
      nil -> llm_explanation(findings)
      fun -> fun.(findings)
    end
  end

  @spec describe_findings(ValidationResult.t()) :: String.t()
  def describe_findings(%ValidationResult{} = validation) do
    []
    |> maybe_add(
      not validation.entity_match.match,
      "Entity name mismatch: #{validation.entity_match.explanation}"
    )
    |> maybe_add(
      not validation.tax_id_valid,
      "Tax ID failed validation against the mock tax registry."
    )
    |> maybe_add(
      validation.sanctions_flagged,
      "Sanctions screening hit: #{validation.sanctions_reason}"
    )
    |> Enum.reverse()
    |> Enum.join("; ")
  end

  defp maybe_add(findings, true, finding), do: [finding | findings]
  defp maybe_add(findings, false, _finding), do: findings

  defp llm_explanation(findings) do
    content = String.replace(@explanation_prompt, "%{findings}", findings)

    case Instructor.chat_completion(
           model: "gpt-4o-mini",
           response_model: %{explanation: :string},
           max_retries: 1,
           messages: [%{role: "user", content: content}]
         ) do
      {:ok, %{explanation: explanation}} -> explanation
      # An explanation is advisory text on an already-decided pause — never
      # a reason to fail the run, so fall back to the raw findings.
      {:error, _reason} -> findings
    end
  end
end
