defmodule DocumentComplianceEngine.Agent.Evals.Deterministic do
  @moduledoc """
  Deterministic (no-LLM) checks — pure functions, no DB, no side effects.
  This is what actually produces the hallucination-rate number; see
  CONTEXT.md's two-tier eval design. Schema validation is the other
  deterministic check, but it's enforced by the extraction changeset
  itself (extraction either returns a valid struct or an error) rather
  than a separate function here — the harness records that per fixture.
  """

  alias DocumentComplianceEngine.Agent.Checks

  @doc """
  Whether the extracted Tax ID appears verbatim in the source W-9 text.
  False means the agent hallucinated a Tax ID it didn't actually read.
  `vendor_contract_w9`-specific — see `fields_grounded?/3` for the general
  form.
  """
  @spec tax_id_verbatim?(String.t() | nil, String.t()) :: boolean()
  def tax_id_verbatim?(nil, _source_text), do: false

  def tax_id_verbatim?(extracted_tax_id, source_text) do
    tax_id = String.trim(extracted_tax_id)
    tax_id != "" and String.contains?(source_text, tax_id)
  end

  @doc """
  Whether every extracted field across every role is grounded in its
  source document — the document-type-generic form of `tax_id_verbatim?/2`,
  reusing the exact production check (`Agent.Checks.
  grounded_extraction_checks/3`) the live pipeline uses to gate approval,
  rather than a second, eval-only reimplementation that could quietly
  drift from what production actually enforces.
  """
  @spec fields_grounded?(%{String.t() => map()}, %{String.t() => String.t()}, map()) :: boolean()
  def fields_grounded?(extracted, documents, shape_signals \\ %{}) do
    Checks.grounded_extraction_checks(extracted, documents, shape_signals) == []
  end

  @doc """
  Whether every field a fixture states an expected value for came back
  with exactly that value. `nil` when the fixture states none, which is
  most of them — this is opt-in per fixture, not a corpus-wide claim.

  Grounding and decision accuracy both have a blind spot this closes: a
  document containing two dates gets an approved, fully-grounded run
  whichever of them lands in `delivery_date`, because both are verbatim
  present. Only naming the right answer can catch a swap. Fixtures use it
  where the *right* value is the thing under test rather than the
  pipeline's reaction to it.
  """
  @spec expected_fields_ok?(%{String.t() => map()}, map() | nil) :: boolean() | nil
  def expected_fields_ok?(_extracted, nil), do: nil
  def expected_fields_ok?(_extracted, expected) when map_size(expected) == 0, do: nil

  def expected_fields_ok?(extracted, expected) do
    Enum.all?(expected, fn {role, fields} ->
      actual = Map.get(extracted, role, %{})

      Enum.all?(fields, fn {field, value} ->
        Map.get(actual, field) == value
      end)
    end)
  end

  @doc """
  The fields that didn't match, for a reviewer of the eval output — an
  `expected_fields_ok?/2` of `false` with no way to see *which* field is a
  number you can't act on.
  """
  @spec expected_field_mismatches(%{String.t() => map()}, map() | nil) :: [String.t()]
  def expected_field_mismatches(_extracted, nil), do: []

  def expected_field_mismatches(extracted, expected) do
    # Deliberately not a comprehension with `actual = ...` as a filter: a
    # nil there (the field never arrived) reads as falsy and drops the row,
    # which silently hides the single most interesting mismatch.
    Enum.flat_map(expected, fn {role, fields} ->
      actual_fields = Map.get(extracted, role, %{})

      Enum.flat_map(fields, fn {field, value} ->
        case Map.get(actual_fields, field) do
          ^value -> []
          actual -> ["#{role}.#{field}: expected #{inspect(value)}, got #{inspect(actual)}"]
        end
      end)
    end)
  end
end
