defmodule DocumentComplianceEngine.AgentFakes do
  @moduledoc """
  Injectable stand-ins for the agent pipeline's LLM and MCP calls, so tests
  never need an OpenAI key or the tool-server processes running. Config
  keys are prefixed `agent_*` since they share `:document_compliance_engine`'s
  application env with the rest of the app now.
  """

  alias DocumentComplianceEngine.Agent.Schemas.EntityMatchResult

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
    Map.merge(
      %{company_name: "Acme Corp", payment_terms: "Net 30", liability_clauses: "Standard."},
      overrides
    )
  end

  def w9(overrides \\ %{}) do
    Map.merge(%{company_name: "Acme Corp", tax_id: "12-3456789"}, overrides)
  end

  @doc "Entity match by exact string comparison — deterministic, no LLM."
  def entity_match(name_a, name_b) do
    match = String.downcase(String.trim(name_a)) == String.downcase(String.trim(name_b))

    {:ok, %EntityMatchResult{match: match, explanation: "fake exact-string comparison"}}
  end

  @doc "Fake extraction, keyed by document role. `contract`/`w9` return the
  fixed fake data above; any other role (e.g. `invoice`) returns each
  configured field name from its schema stringified as its own value."
  def extract(role, response_model, _text) do
    case role do
      "contract" ->
        {:ok, contract()}

      "w9" ->
        {:ok, w9()}

      _ ->
        {:ok, Map.new(response_model, fn {field, _type} -> {field, "fake-#{role}-#{field}"} end)}
    end
  end

  def defaults do
    [
      extract: &extract/3,
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
