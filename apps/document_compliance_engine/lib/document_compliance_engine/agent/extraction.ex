defmodule DocumentComplianceEngine.Agent.Extraction do
  @moduledoc """
  Agent 1: one structured-output LLM call per document. Kept as two
  separate calls (not one merged call) so Agent 2 has two independent
  company names to cross-check.

  Both functions are overridable via application config so tests never need
  a real OpenAI key — the Elixir equivalent of the fake-extractor injection
  the Python graph used.
  """

  alias DocumentComplianceEngine.Agent.Schemas.{ContractExtraction, W9Extraction}

  @contract_prompt "Extract the company name, payment terms, and liability clauses from the following vendor contract.\n\n"
  @w9_prompt "Extract the company name and Tax ID exactly as written from the following W-9 form.\n\n"

  @spec extract_contract(String.t()) :: {:ok, ContractExtraction.t()} | {:error, term()}
  def extract_contract(text) do
    case Application.get_env(:document_compliance_engine, :agent_extract_contract) do
      nil -> complete(ContractExtraction, @contract_prompt <> text)
      fun -> fun.(text)
    end
  end

  @spec extract_w9(String.t()) :: {:ok, W9Extraction.t()} | {:error, term()}
  def extract_w9(text) do
    case Application.get_env(:document_compliance_engine, :agent_extract_w9) do
      nil -> complete(W9Extraction, @w9_prompt <> text)
      fun -> fun.(text)
    end
  end

  defp complete(response_model, content) do
    Instructor.chat_completion(
      model: "gpt-4o-mini",
      response_model: response_model,
      max_retries: 1,
      messages: [%{role: "user", content: content}]
    )
  end
end
