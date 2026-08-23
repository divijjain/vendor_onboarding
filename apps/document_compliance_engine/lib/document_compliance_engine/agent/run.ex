defmodule DocumentComplianceEngine.Agent.Run do
  @moduledoc """
  Drives `DocumentReactor` and reports its outcome directly to the
  `AgentRuns` context — replaces what used to be an HTTP callback to a
  separate `agent_service` process, now that the pipeline runs in-process
  inside the triggering Oban job. A halt persists a checkpoint row (the
  serialized reactor plus the original inputs, which Reactor requires
  again at resume) so the pause survives a restart of this app.

  Reporting is always `:ok` even when the write back to `AgentRuns` fails
  (logged, not propagated) — preserves the previous callback's semantics
  exactly: retrying the *whole* pipeline from an Oban retry would replay
  extraction/validation and hit the checkpoint's unique `thread_id`
  constraint on a halt, which is worse than a logged, swallowed error.
  """

  require Logger

  alias DocumentComplianceEngine.Agent.Checkpoint.Repository
  alias DocumentComplianceEngine.Agent.DocumentReactor
  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentTypes
  alias DocumentComplianceEngine.PdfText
  alias DocumentComplianceEngine.Storage

  # Extracted roles this app currently has dedicated AgentRun columns for.
  # Any other role's fields land in the generic `extracted_fields` column
  # instead — e.g. today's second type, `invoice`, has none of these.
  @known_roles ~w(contract w9)

  @spec trigger(pos_integer(), String.t(), map()) :: :ok
  def trigger(document_job_id, document_type_slug, document_paths) do
    with {:ok, document_type} <- fetch_document_type(document_type_slug),
         {:ok, documents} <- read_documents(document_paths, document_type.extraction_schema) do
      inputs = %{
        document_type_slug: document_type_slug,
        documents: documents,
        extraction_schema: document_type.extraction_schema,
        validation_rules: document_type.validation_rules,
        shape_signals: document_type.shape_signals,
        human_decision: nil
      }

      DocumentReactor
      |> Reactor.run(inputs)
      |> handle_result(document_job_id, inputs)
    else
      {:error, reason} -> fail(document_job_id, reason)
    end
  end

  @spec resume(pos_integer(), String.t(), String.t()) :: :ok
  def resume(document_job_id, thread_id, decision) do
    case Repository.get_by_thread_id(thread_id) do
      {:ok, checkpoint} ->
        reactor = :erlang.binary_to_term(checkpoint.reactor_state)
        inputs = resume_inputs(checkpoint, decision)

        Repository.mark_resumed(checkpoint)

        reactor
        |> Reactor.run(inputs, %{})
        |> handle_result(document_job_id, inputs)

      {:error, :not_found} ->
        fail(document_job_id, "no checkpoint for thread_id #{thread_id}")
    end
  end

  defp fetch_document_type(slug) do
    case DocumentTypes.get_document_type_by_slug(slug) do
      nil -> {:error, "unknown document type: #{slug}"}
      document_type -> {:ok, document_type}
    end
  end

  defp read_documents(document_paths, extraction_schema) do
    extraction_schema
    |> Map.keys()
    |> Enum.reduce_while({:ok, %{}}, fn role, {:ok, acc} ->
      with path when not is_nil(path) <- document_paths[role],
           {:ok, bytes} <- Storage.read(path),
           {:ok, text} <- PdfText.extract(bytes) do
        {:cont, {:ok, Map.put(acc, role, text)}}
      else
        nil -> {:halt, {:error, "missing document path: #{role}"}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resume_inputs(checkpoint, decision) do
    %{
      document_type_slug: checkpoint.inputs["document_type_slug"],
      documents: checkpoint.inputs["documents"],
      extraction_schema: checkpoint.inputs["extraction_schema"],
      validation_rules: checkpoint.inputs["validation_rules"],
      shape_signals: checkpoint.inputs["shape_signals"] || %{},
      human_decision: decision
    }
  end

  defp handle_result({:ok, result}, document_job_id, _inputs) do
    report(
      Map.merge(
        %{"document_job_id" => document_job_id, "status" => result.status},
        extracted_payload(result.extracted, result.extraction_metadata)
      )
    )
  end

  defp handle_result({:halted, reactor}, document_job_id, inputs) do
    {extracted, extraction_metadata, explanation} = halted_details(reactor)
    thread_id = thread_id_for(document_job_id)

    # thread_id is deterministic per document_job_id, so a fresh halt always
    # supersedes any prior, unresolved checkpoint for the same document_job
    # (e.g. an earlier attempt that was interrupted before ever reaching
    # review) — otherwise this insert hits `run_checkpoints`' unique
    # `thread_id` constraint, and a discarded `{:error, changeset}` here
    # would leave `agent_runs` pointing at that stale checkpoint instead of
    # this run's actual state.
    Repository.delete_by_thread_id(thread_id)

    {:ok, _checkpoint} =
      Repository.insert(%{
        thread_id: thread_id,
        document_job_id: document_job_id,
        reactor_state: :erlang.term_to_binary(reactor),
        inputs: %{
          "document_type_slug" => inputs.document_type_slug,
          "documents" => inputs.documents,
          "extraction_schema" => inputs.extraction_schema,
          "validation_rules" => inputs.validation_rules,
          "shape_signals" => inputs.shape_signals
        },
        explanation: explanation
      })

    report(
      Map.merge(
        %{
          "document_job_id" => document_job_id,
          "status" => "needs_review",
          "thread_id" => thread_id,
          "explanation" => truncate(explanation)
        },
        extracted_payload(extracted, extraction_metadata)
      )
    )
  end

  defp handle_result({:error, reason}, document_job_id, _inputs) do
    fail(document_job_id, reason)
  end

  defp halted_details(reactor) do
    results = reactor.intermediate_results || %{}
    extract_result = results[:extract] || %{}

    explanation =
      case results[:gate] do
        {:awaiting_human, explanation} -> explanation
        _ -> nil
      end

    {extract_result[:fields] || %{}, extract_result[:metadata] || %{}, explanation}
  end

  # Known roles (contract/w9) still populate AgentRun's fixed columns
  # exactly like before — zero behavior change for the original document
  # type. Everything else goes into `extracted_fields`, deliberately never
  # the Tax ID column: that stays populated only from the `w9` role's
  # dedicated encrypted column, never swept into this generic (unencrypted)
  # map, so no future document type's extraction can land PII there by
  # accident.
  defp extracted_payload(extracted, extraction_metadata) do
    contract = extracted["contract"] || %{}
    w9 = extracted["w9"] || %{}

    extracted_fields =
      extracted
      |> Enum.reject(fn {role, _fields} -> role in @known_roles end)
      |> Map.new(fn {role, fields} -> {role, stringify_keys(fields)} end)

    %{
      "company_name" => contract[:company_name],
      "w9_company_name" => w9[:company_name],
      "tax_id" => w9[:tax_id],
      "payment_terms" => contract[:payment_terms],
      "liability_clauses" => contract[:liability_clauses],
      "extracted_fields" => extracted_fields,
      "extraction_metadata" => stringify_metadata(extraction_metadata)
    }
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)

  # Same PII exclusion as `extracted_payload/2`'s `extracted_fields`, and
  # for the same reason: a regex-resolved `tax_id`'s synthesized
  # `source_quote` *is* the raw Tax ID (see `Extraction.regex_metadata/1`),
  # and this column isn't encrypted — Tax ID confidence/grounding data
  # must never land here, by construction.
  defp stringify_metadata(extraction_metadata) do
    Map.new(extraction_metadata, fn {role, fields} ->
      {role,
       fields
       |> Map.delete(:tax_id)
       |> Map.new(fn {field, entry} ->
         {Atom.to_string(field),
          %{"confidence" => entry[:confidence], "source_quote" => entry[:source_quote]}}
       end)}
    end)
  end

  @spec thread_id_for(pos_integer()) :: String.t()
  def thread_id_for(document_job_id), do: "document_job-#{document_job_id}"

  # `agent_runs.explanation` is a varchar(255) — the full inspected reason
  # goes to the logs above, but a Reactor error struct can be arbitrarily
  # long, so only a truncated summary is written to the row.
  @explanation_limit 200

  defp fail(document_job_id, reason) do
    Logger.error("agent run failed for document_job #{document_job_id}: #{inspect(reason)}")

    report(%{
      "document_job_id" => document_job_id,
      "status" => "failed",
      "explanation" => "Agent run failed: #{truncate(inspect(reason))}"
    })
  end

  defp truncate(text) when byte_size(text) > @explanation_limit do
    String.slice(text, 0, @explanation_limit) <> "..."
  end

  defp truncate(text), do: text

  defp report(payload) do
    callback_fun =
      Application.get_env(
        :document_compliance_engine,
        :agent_callback_fun,
        &AgentRuns.handle_agent_callback/1
      )

    case callback_fun.(payload) do
      {:ok, _agent_run} ->
        :ok

      {:error, reason} ->
        Logger.error("failed to record agent run result: #{inspect(reason)}")
        :ok
    end
  end
end
