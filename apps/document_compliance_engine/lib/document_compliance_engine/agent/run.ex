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
           {:ok, bytes} <- File.read(path),
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
      human_decision: decision
    }
  end

  defp handle_result({:ok, result}, document_job_id, _inputs) do
    report(
      Map.merge(
        %{"document_job_id" => document_job_id, "status" => result.status},
        extracted_payload(result.extracted)
      )
    )
  end

  defp handle_result({:halted, reactor}, document_job_id, inputs) do
    {extracted, explanation} = halted_details(reactor)

    Repository.insert(%{
      thread_id: thread_id_for(document_job_id),
      document_job_id: document_job_id,
      reactor_state: :erlang.term_to_binary(reactor),
      inputs: %{
        "document_type_slug" => inputs.document_type_slug,
        "documents" => inputs.documents,
        "extraction_schema" => inputs.extraction_schema,
        "validation_rules" => inputs.validation_rules
      },
      explanation: explanation
    })

    report(
      Map.merge(
        %{
          "document_job_id" => document_job_id,
          "status" => "needs_review",
          "thread_id" => thread_id_for(document_job_id),
          "explanation" => explanation
        },
        extracted_payload(extracted)
      )
    )
  end

  defp handle_result({:error, reason}, document_job_id, _inputs) do
    fail(document_job_id, reason)
  end

  defp halted_details(reactor) do
    results = reactor.intermediate_results || %{}

    explanation =
      case results[:gate] do
        {:awaiting_human, explanation} -> explanation
        _ -> nil
      end

    {results[:extract] || %{}, explanation}
  end

  # Known roles (contract/w9) still populate AgentRun's fixed columns
  # exactly like before — zero behavior change for the original document
  # type. Everything else goes into `extracted_fields`, deliberately never
  # the Tax ID column: that stays populated only from the `w9` role's
  # dedicated encrypted column, never swept into this generic (unencrypted)
  # map, so no future document type's extraction can land PII there by
  # accident.
  defp extracted_payload(extracted) do
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
      "extracted_fields" => extracted_fields
    }
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)

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
