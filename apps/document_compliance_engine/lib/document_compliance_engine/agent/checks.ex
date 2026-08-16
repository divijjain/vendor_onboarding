defmodule DocumentComplianceEngine.Agent.Checks do
  @moduledoc """
  Agent 2: interprets a document type's `validation_rules` against the
  extracted data. Two rule types:

    - `entity_match` — an LLM judgment comparing two named fields (e.g.
      the contract's and W-9's company names)
    - `mcp_tool` — calls one of the two known MCP tools
      (`validate_tax_id`/`screen_vendor`) against one named field

  The two tools themselves stay a fixed, known pair — only which
  document/field feeds them varies by document type, so their
  human-readable failure messages stay hardcoded per tool rather than
  generated generically.
  """

  alias DocumentComplianceEngine.Agent.McpClient
  alias DocumentComplianceEngine.Agent.Schemas.EntityMatchResult
  alias DocumentComplianceEngine.Agent.ValidationResult

  @entity_match_prompt """
  Do these two names refer to the same legal entity? Minor formatting \
  differences (abbreviations, punctuation, "Corp" vs "Corporation") are still a \
  match; a genuinely different vendor name is not.

  Name A: %{name_a}
  Name B: %{name_b}
  """

  @explanation_prompt """
  Draft a brief, concrete explanation of the discrepancy found while validating \
  this document job, grounded only in the facts below. Do not invent details.

  %{findings}
  """

  @spec validate_all(%{String.t() => map()}, [map()]) ::
          {:ok, ValidationResult.t()} | {:error, term()}
  def validate_all(extracted, validation_rules) do
    validation_rules
    |> Enum.reduce_while({:ok, []}, fn rule, {:ok, acc} ->
      case run_rule(rule, extracted) do
        {:ok, check} -> {:cont, {:ok, [check | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, checks} -> {:ok, %ValidationResult{checks: Enum.reverse(checks)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_rule(%{"type" => "entity_match", "fields" => [a, b]} = rule, extracted) do
    with {:ok, result} <- entity_match(field_value(extracted, a), field_value(extracted, b)) do
      {:ok,
       %{
         rule: rule,
         passed: result.match,
         detail: unless(result.match, do: "Entity name mismatch: #{result.explanation}")
       }}
    end
  end

  defp run_rule(
         %{"type" => "mcp_tool", "tool" => "validate_tax_id", "field" => field} = rule,
         extracted
       ) do
    with {:ok, %{valid: valid}} <- McpClient.validate_tax_id(field_value(extracted, field)) do
      {:ok,
       %{
         rule: rule,
         passed: valid,
         detail: unless(valid, do: "Tax ID failed validation against the mock tax registry.")
       }}
    end
  end

  defp run_rule(
         %{"type" => "mcp_tool", "tool" => "screen_vendor", "field" => field} = rule,
         extracted
       ) do
    with {:ok, %{flagged: flagged, reason: reason}} <-
           McpClient.screen_vendor(field_value(extracted, field)) do
      {:ok,
       %{
         rule: rule,
         passed: not flagged,
         detail: if(flagged, do: "Sanctions screening hit: #{reason}")
       }}
    end
  end

  defp field_value(extracted, %{"role" => role, "name" => name}) do
    extracted
    |> Map.fetch!(role)
    |> Map.fetch!(String.to_existing_atom(name))
  end

  @spec entity_match(String.t(), String.t()) :: {:ok, EntityMatchResult.t()} | {:error, term()}
  def entity_match(name_a, name_b) do
    case Application.get_env(:document_compliance_engine, :agent_entity_match) do
      nil ->
        content =
          String.replace(@entity_match_prompt, "%{name_a}", name_a)
          |> String.replace("%{name_b}", name_b)

        Instructor.chat_completion(
          model: "gpt-4o-mini",
          response_model: EntityMatchResult,
          max_retries: 1,
          messages: [%{role: "user", content: content}]
        )

      fun ->
        fun.(name_a, name_b)
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
    validation
    |> ValidationResult.failed_checks()
    |> Enum.map(& &1.detail)
    |> Enum.join("; ")
  end

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
