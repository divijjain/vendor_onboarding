defmodule DocumentComplianceEngine.DocumentTypeLibraryTest do
  @moduledoc """
  Walks **every** document type in the registry through the real pipeline —
  webhook ingestion, the reactor, validation, the final status — with no
  per-type branching anywhere in the test body. The type list comes from
  `DocumentTypes.list_document_types/0`, not a hardcoded list, so a
  document type added as a data migration is covered by this the moment
  it is seeded, and one that isn't genuinely supported by the generic
  pipeline fails here rather than in production.

  The synthetic document for each type is generated from its own config:
  its `shape_signals` keywords (so the shape gate passes), and one value
  per field derived from that field's declared type (so the declared-type
  checks pass), written into the text verbatim (so grounding passes). The
  test therefore asserts something stronger than "the pipeline ran" — it
  asserts that a document genuinely consistent with a type's own config
  reaches `:approved`, which is exactly what the config claims.
  """

  use DocumentComplianceEngine.DataCase, async: false

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.Agent.ExtractionSchema
  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentJobs
  alias DocumentComplianceEngine.DocumentTypes

  # Values chosen to satisfy the checks a document type can configure:
  # `iban` runs a real mod-97 checksum and `bic` a real pattern (both on
  # `bank_details`), so neither can be a placeholder string.
  @iban "GB82WEST12345698765432"
  @bic "DEUTDEFF"

  test "every seeded document type runs end to end and auto-approves a consistent document" do
    document_types = DocumentTypes.list_document_types()

    # Guards against this test silently passing on an empty registry.
    assert length(document_types) >= 9

    for document_type <- document_types do
      values = field_values(document_type)

      documents =
        Enum.map(values, fn {role, fields} ->
          {role, document_text(fields, document_type.shape_signals[role])}
        end)

      stub_defaults(
        extract: fn role, response_model, _text ->
          {:ok, Map.new(response_model, fn {field, _type} -> {field, values[role][field]} end)}
        end
      )

      document_job = ingest(document_type, documents)

      assert {:ok, _run} = AgentRuns.trigger_agent_run(document_job.id)
      assert {:ok, updated} = DocumentJobs.get_document_job(document_job.id)

      {:ok, run} = AgentRuns.get_latest_for_document_job(document_job.id)

      assert updated.status == :approved,
             "#{document_type.slug} did not auto-approve: #{inspect(run.explanation)}"
    end
  end

  test "every seeded document type declares a description a classifier could reason over" do
    for document_type <- DocumentTypes.list_document_types() do
      assert is_binary(document_type.description) and
               String.length(document_type.description) > 80,
             "#{document_type.slug} has no usable description"
    end
  end

  test "every seeded document type's extraction_schema is well-formed config" do
    for document_type <- DocumentTypes.list_document_types() do
      assert :ok = ExtractionSchema.validate(document_type.extraction_schema),
             "#{document_type.slug} has a malformed extraction_schema"
    end
  end

  defp ingest(document_type, documents) do
    raw_payload =
      Jason.encode!(%{
        "document_type_slug" => document_type.slug,
        "documents" => Map.new(documents, fn {role, text} -> {role, Base.encode64(text)} end),
        "owner_email" => "library-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, document_job} = DocumentJobs.ingest_webhook(raw_payload)

    on_exit(fn ->
      document_job.document_paths
      |> Map.values()
      |> List.first()
      |> Path.dirname()
      |> File.rm_rf()
    end)

    document_job
  end

  # One plausible value per field, derived from the field's own declared
  # type — the same config the pipeline will check the value against.
  defp field_values(document_type) do
    Map.new(document_type.extraction_schema, fn {role, field_specs} ->
      fields =
        Map.new(field_specs, fn {field, spec} ->
          {String.to_atom(field), value_for(field, ExtractionSchema.type(spec))}
        end)

      {role, fields}
    end)
  end

  # Fields whose *name* implies a scheme a rule will check, which no
  # generic value could satisfy — the `format`/`regex` rules exist precisely
  # because these can't be guessed from the declared type.
  defp value_for("iban", _type), do: @iban
  defp value_for("bic", _type), do: @bic
  defp value_for("vat_id", _type), do: "DE123456789"
  defp value_for("registered_address", _type), do: "12 Dockside Road, Glasgow G51 2QT"
  defp value_for(_field, "monetary_amount"), do: "1,234.56"
  defp value_for(_field, "email"), do: "vendor@example.com"
  defp value_for(_field, "phone"), do: "+44 20 7555 0100"
  defp value_for(_field, "uri"), do: "https://vendor.example.com"
  defp value_for(_field, "number"), do: "42"
  # Relative to today, not a literal: `certificate_of_insurance` carries a
  # `not_expired` rule, and a hardcoded date turns this test into one that
  # passes until it doesn't.
  defp value_for(_field, "date"), do: Date.utc_today() |> Date.add(30) |> Date.to_iso8601()
  # Every name-ish field gets the *same* company name on purpose: the
  # `vendor_contract_w9` type's entity_match rule compares two of them
  # across two documents, and a consistent document is one where they agree.
  defp value_for(_field, _type), do: "Acme Corp"

  # The document a type's own config describes: its own `shape_signals`
  # keywords (so the gate it configured for itself passes), then every field
  # value verbatim so the grounding check can find it. Taken from the type
  # rather than from a list maintained here — a hardcoded vocabulary is a
  # second place to update every time a type is seeded, and forgetting is
  # indistinguishable from the pipeline not supporting the type.
  defp document_text(fields, shape) do
    lines = Enum.map_join(fields, "\n", fn {field, value} -> "#{field}: #{value}" end)
    keywords = shape |> Kernel.||(%{}) |> Map.get("keywords", []) |> Enum.join(" ")

    "#{keywords}\n\n#{lines}\n"
  end
end
