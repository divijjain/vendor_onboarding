defmodule DocumentComplianceEngine.AgentFakes do
  @moduledoc """
  Injectable stand-ins for the agent pipeline's LLM and MCP calls, so tests
  never need an OpenAI key or the tool-server processes running. Config
  keys are prefixed `agent_*` since they share `:document_compliance_engine`'s
  application env with the rest of the app now.
  """

  alias DocumentComplianceEngine.Agent.Schemas.{
    ContractExtraction,
    EntityMatchResult,
    W9Extraction
  }

  @doc "Overrides the agent's external calls for the duration of one test."
  def stub(overrides) do
    Enum.each(overrides, fn {key, fun} ->
      Application.put_env(:document_compliance_engine, :"agent_#{key}", fun)
    end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(overrides, fn {key, _fun} ->
        Application.delete_env(:document_compliance_engine, :"agent_#{key}")
      end)
    end)
  end

  def contract(overrides \\ %{}) do
    struct(
      %ContractExtraction{
        company_name: "Acme Corp",
        payment_terms: "Net 30",
        liability_clauses: "Standard."
      },
      overrides
    )
  end

  def w9(overrides \\ %{}) do
    struct(%W9Extraction{company_name: "Acme Corp", tax_id: "12-3456789"}, overrides)
  end

  @doc "Entity match by exact string comparison — deterministic, no LLM."
  def entity_match(contract_name, w9_name) do
    match = String.downcase(String.trim(contract_name)) == String.downcase(String.trim(w9_name))

    {:ok, %EntityMatchResult{match: match, explanation: "fake exact-string comparison"}}
  end

  def defaults do
    [
      extract_contract: fn _text -> {:ok, contract()} end,
      extract_w9: fn _text -> {:ok, w9()} end,
      entity_match: &entity_match/2,
      validate_tax_id: fn _tax_id -> {:ok, %{valid: true}} end,
      screen_vendor: fn _name -> {:ok, %{flagged: false, reason: nil}} end,
      draft_explanation: fn findings -> "Explanation: #{findings}" end
    ]
  end

  @doc "Stubs every external call, with per-test overrides merged in."
  def stub_defaults(overrides \\ []) do
    defaults() |> Keyword.merge(overrides) |> stub()
  end
end
