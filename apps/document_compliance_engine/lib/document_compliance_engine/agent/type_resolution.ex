defmodule DocumentComplianceEngine.Agent.TypeResolution do
  @moduledoc """
  Turns a `Classification` result into the config the rest of the pipeline
  actually runs on: the chosen type's `extraction_schema`,
  `validation_rules` and `shape_signals`, plus the uploaded documents
  re-keyed onto that type's roles.

  **Nothing here ever fails the run.** Every way this can go wrong — an
  unconfident classification, no classifiable type at all, documents that
  don't line up with the chosen type's roles — comes back as a resolution
  with an empty `extraction_schema` and a failed *check*. An empty schema
  makes extraction a genuine no-op (`Extraction.extract_all/3` over no
  roles costs nothing and returns no fields), the check flows into the
  same `ValidationResult` every other finding does, and `:gate` halts the
  run to human review through the machinery that already exists. That is
  why there is no second pause mechanism and no conditional step in the
  reactor: "we don't know what this document is" is expressed as a
  finding, not as control flow.

  **Role mapping.** A caller who names their uploads `contract`/`w9`
  already agrees with the type's roles and is passed through untouched.
  A caller who doesn't know what they're sending — the case classification
  exists for — has no way to know the role names either, so a single
  uploaded document is mapped onto a single-role type's role whatever key
  it arrived under. Anything else (two uploads, three roles, mismatched
  names) is not guessed at: it is reported, because silently pairing the
  wrong file with the wrong role would produce a confidently wrong
  extraction rather than an honest question.
  """

  alias DocumentComplianceEngine.Agent.Classification
  alias DocumentComplianceEngine.Agent.ValidationResult

  @type t :: %{
          document_type_slug: String.t() | nil,
          extraction_schema: map(),
          validation_rules: [map()],
          shape_signals: map(),
          documents: %{String.t() => String.t()},
          checks: [ValidationResult.check()]
        }

  @doc """
  Resolves the config for one run. `candidates` are the string-keyed
  document-type rows `Classification` chose among.
  """
  @spec resolve(Classification.result(), [Classification.candidate()], %{
          String.t() => String.t()
        }) :: t()
  def resolve(classification, candidates, documents) do
    candidate = Enum.find(candidates, &(&1["slug"] == classification.slug))

    cond do
      is_nil(candidate) -> unresolved(classification, documents)
      not classification.confident? -> unconfident(classification, candidate, documents)
      true -> confident(classification, candidate, documents)
    end
  end

  defp unresolved(classification, documents) do
    %{
      document_type_slug: nil,
      extraction_schema: %{},
      validation_rules: [],
      shape_signals: %{},
      documents: documents,
      checks: [
        check(
          "classification",
          nil,
          classification,
          "Could not determine what kind of document this is, so nothing was extracted from it" <>
            reasoning_suffix(classification) <> " — a human needs to identify it."
        )
      ]
    }
  end

  # The proposed type is still used to extract: the reviewer's question is
  # "is this a purchase_order?", and the fields the pipeline pulled out
  # under that assumption are the evidence that answers it. Extracting
  # nothing would hand them the question with none of the evidence.
  defp unconfident(classification, candidate, documents) do
    resolution = confident(classification, candidate, documents)

    detail =
      "Classified as #{classification.slug} with low confidence " <>
        "(#{format_confidence(classification.confidence)}, below the " <>
        "#{format_confidence(Classification.confidence_threshold())} threshold)" <>
        reasoning_suffix(classification) <>
        " — extracted below on that assumption, for a human to confirm."

    # Prepended, not replaced: if the documents *also* failed to line up
    # with this type's roles, that finding is still the reviewer's
    # business — and dropping it would leave an empty extraction with no
    # stated reason.
    %{
      resolution
      | checks: [
          check("classification", classification.slug, classification, detail) | resolution.checks
        ]
    }
  end

  defp confident(classification, candidate, documents) do
    case map_roles(documents, candidate) do
      {:ok, mapped} ->
        %{
          document_type_slug: classification.slug,
          extraction_schema: candidate["extraction_schema"] || %{},
          validation_rules: candidate["validation_rules"] || [],
          shape_signals: candidate["shape_signals"] || %{},
          documents: mapped,
          checks: []
        }

      {:error, roles} ->
        %{
          document_type_slug: classification.slug,
          extraction_schema: %{},
          validation_rules: [],
          shape_signals: %{},
          documents: documents,
          checks: [
            check(
              "document_roles",
              classification.slug,
              classification,
              "This job's #{length(Map.keys(documents))} document(s) " <>
                "(#{Enum.join(Enum.sort(Map.keys(documents)), ", ")}) could not be matched to " <>
                "#{classification.slug}'s roles (#{Enum.join(Enum.sort(roles), ", ")}), so " <>
                "nothing was extracted — a human needs to say which document is which."
            )
          ]
        }
    end
  end

  defp map_roles(documents, candidate) do
    roles = Map.keys(candidate["extraction_schema"] || %{})
    uploaded = Map.keys(documents)

    cond do
      MapSet.equal?(MapSet.new(roles), MapSet.new(uploaded)) ->
        {:ok, documents}

      match?({[_role], [_upload]}, {roles, uploaded}) ->
        {:ok, %{hd(roles) => documents[hd(uploaded)]}}

      true ->
        {:error, roles}
    end
  end

  defp check(type, slug, classification, detail) do
    %{
      rule: %{
        "type" => type,
        "document_type_slug" => slug,
        "confidence" => classification.confidence,
        "source" => to_string(classification.source)
      },
      passed: false,
      detail: detail
    }
  end

  defp reasoning_suffix(%{reasoning: reasoning}) when is_binary(reasoning) and reasoning != "",
    do: ": #{reasoning}"

  defp reasoning_suffix(_classification), do: ""

  defp format_confidence(confidence), do: :erlang.float_to_binary(confidence * 1.0, decimals: 2)
end
