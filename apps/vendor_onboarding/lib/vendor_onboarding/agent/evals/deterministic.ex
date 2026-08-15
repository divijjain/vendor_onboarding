defmodule VendorOnboarding.Agent.Evals.Deterministic do
  @moduledoc """
  Deterministic (no-LLM) checks — pure functions, no DB, no side effects.
  This is what actually produces the hallucination-rate number; see
  CONTEXT.md's two-tier eval design. Schema validation is the other
  deterministic check, but it's enforced by the extraction changeset
  itself (extraction either returns a valid struct or an error) rather
  than a separate function here — the harness records that per fixture.
  """

  @doc """
  Whether the extracted Tax ID appears verbatim in the source W-9 text.
  False means the agent hallucinated a Tax ID it didn't actually read.
  """
  @spec tax_id_verbatim?(String.t() | nil, String.t()) :: boolean()
  def tax_id_verbatim?(nil, _source_text), do: false

  def tax_id_verbatim?(extracted_tax_id, source_text) do
    tax_id = String.trim(extracted_tax_id)
    tax_id != "" and String.contains?(source_text, tax_id)
  end
end
