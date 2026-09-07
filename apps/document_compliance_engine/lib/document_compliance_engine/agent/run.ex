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
  alias DocumentComplianceEngine.Agent.Classification
  alias DocumentComplianceEngine.Agent.DocumentReactor
  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.DocumentTypes
  alias DocumentComplianceEngine.PdfText
  alias DocumentComplianceEngine.Storage

  # Extracted roles this app currently has dedicated AgentRun columns for.
  # Any other role's fields land in the generic `extracted_fields` column
  # instead — e.g. today's second type, `invoice`, has none of these.
  @known_roles ~w(contract w9)

  # Telemetry metadata deliberately carries `document_job_id` (useful for a
  # log/trace-based handler to correlate one run), but PromEx/Telemetry.Metrics
  # tags below only ever key on `status`/`document_type_slug` — both small,
  # fixed sets. Tagging a Prometheus metric by `document_job_id` would mint a
  # brand-new time series per document forever; the event metadata and the
  # metric tags are different things on purpose.
  @spec trigger(pos_integer(), String.t(), map()) :: :ok
  def trigger(document_job_id, document_type_slug, document_paths) do
    :telemetry.span(
      [:document_compliance_engine, :agent_run],
      %{document_job_id: document_job_id, document_type_slug: document_type_slug},
      fn ->
        status = do_trigger(document_job_id, document_type_slug, document_paths)

        {:ok,
         %{
           document_job_id: document_job_id,
           status: status,
           document_type_slug: document_type_slug
         }}
      end
    )
  end

  defp do_trigger(document_job_id, document_type_slug, document_paths) do
    with {:ok, documents} <- read_documents(document_paths) do
      inputs = %{
        document_type_slug: document_type_slug,
        documents: documents,
        document_types: candidates(),
        human_decision: nil
      }

      DocumentReactor
      |> Reactor.run(inputs)
      |> handle_result(document_job_id, inputs)
    else
      {:error, reason} -> fail(document_job_id, reason)
    end
  end

  # The whole registry, as the string-keyed config the reactor's inputs
  # (and therefore the checkpoint's jsonb `inputs`) carry. Read once here
  # rather than inside a step, for the same reason the resolved schema
  # used to be: it is static config, and a resumed run must see exactly
  # the candidates the original run saw, not whatever the registry looks
  # like whenever the human gets round to reviewing.
  defp candidates do
    Classification.candidates(DocumentTypes.list_document_types())
  end

  @spec resume(pos_integer(), String.t(), String.t()) :: :ok
  def resume(document_job_id, thread_id, decision) do
    :telemetry.span(
      [:document_compliance_engine, :agent_run],
      %{document_job_id: document_job_id, thread_id: thread_id},
      fn ->
        {status, document_type_slug} = do_resume(document_job_id, thread_id, decision)

        {:ok,
         %{
           document_job_id: document_job_id,
           status: status,
           document_type_slug: document_type_slug
         }}
      end
    )
  end

  defp do_resume(document_job_id, thread_id, decision) do
    case Repository.get_by_thread_id(thread_id) do
      # A checkpoint whose payload has been purged is one that already ran
      # to completion (see `Repository.purge_payload/1`). Reported as a
      # failed resume rather than reaching `binary_to_term(nil)`, which is
      # what a second decision on the same thread used to do.
      {:ok, %{reactor_state: nil}} ->
        {fail(document_job_id, "checkpoint for thread_id #{thread_id} was already resumed"), nil}

      {:ok, checkpoint} ->
        reactor = :erlang.binary_to_term(checkpoint.reactor_state)
        inputs = resume_inputs(checkpoint, decision)

        Repository.mark_resumed(checkpoint)

        status =
          reactor
          |> Reactor.run(inputs, %{})
          |> handle_result(document_job_id, inputs)

        # After the run, never before: a crash mid-resume must leave
        # something to resume from.
        Repository.purge_payload(checkpoint)

        {status, inputs.document_type_slug}

      {:error, :not_found} ->
        {fail(document_job_id, "no checkpoint for thread_id #{thread_id}"), nil}
    end
  end

  # Reads every uploaded document, under whatever key it was uploaded with.
  # This used to iterate the resolved type's roles, which is no longer
  # possible: the type isn't known until the documents have been read and
  # classified. `TypeResolution` re-keys them onto the chosen type's roles
  # afterwards.
  defp read_documents(document_paths) do
    Enum.reduce_while(document_paths, {:ok, %{}}, fn {role, path}, {:ok, acc} ->
      with {:ok, bytes} <- Storage.read(path),
           {:ok, text} <- PdfText.extract(bytes) do
        {:cont, {:ok, Map.put(acc, role, text)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resume_inputs(checkpoint, decision) do
    %{
      document_type_slug: checkpoint.inputs["document_type_slug"],
      documents: checkpoint.inputs["documents"],
      document_types: checkpoint.inputs["document_types"] || [],
      human_decision: decision
    }
  end

  defp handle_result({:ok, result}, document_job_id, _inputs) do
    report(
      Map.merge(
        %{
          "document_job_id" => document_job_id,
          "status" => result.status,
          # What the run actually ran as, which for a job ingested without
          # a type is the classifier's answer — see `HandleAgentCallback`.
          "document_type_slug" => result.document_type_slug
        },
        extracted_payload(result.extracted, result.extraction_metadata)
      )
    )
  end

  defp handle_result({:halted, reactor}, document_job_id, inputs) do
    {extracted, extraction_metadata, explanation, classified_slug} = halted_details(reactor)
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
          "document_types" => storable_candidates(inputs.document_types, classified_slug)
        },
        explanation: explanation
      })

    report(
      Map.merge(
        %{
          "document_job_id" => document_job_id,
          "status" => "needs_review",
          "thread_id" => thread_id,
          "explanation" => truncate(explanation),
          "document_type_slug" => classified_slug
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

    # A halted run still knows what it decided the document was — that's
    # exactly what the reviewer is being asked about when the halt came
    # from a low-confidence classification.
    classified_slug =
      case results[:resolve_type] do
        %{document_type_slug: slug} -> slug
        _ -> nil
      end

    {extract_result[:fields] || %{}, extract_result[:metadata] || %{}, explanation,
     classified_slug}
  end

  # The candidate list is the largest thing in a checkpoint (measured: ~1.2KB
  # per document type, against 141 bytes of document text on a typical
  # fixture), and most of that bulk is `extraction_schema`/`validation_rules`
  # for types this run didn't pick. Only the *winning* candidate's config is
  # ever read again — `TypeResolution` looks up exactly one — while
  # `Classification` reads nothing but slug/name/description/shape_signals
  # from any of them. So the losers are stored with just those four fields:
  # both steps would behave identically if they ever re-ran, and the row
  # still records which alternatives this run chose among, which is the part
  # worth keeping for an audit.
  @classification_fields ~w(slug name description shape_signals)

  defp storable_candidates(candidates, winning_slug) do
    Enum.map(candidates, fn candidate ->
      if candidate["slug"] == winning_slug do
        candidate
      else
        Map.take(candidate, @classification_fields)
      end
    end)
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

  # Returns the run's final status (for the telemetry span in trigger/1 and
  # resume/3 to tag with) regardless of whether persisting the report itself
  # succeeded — a failed write-back doesn't change what the pipeline actually
  # decided, it only means that decision wasn't recorded (logged above).
  defp report(payload) do
    callback_fun =
      Application.get_env(
        :document_compliance_engine,
        :agent_callback_fun,
        &AgentRuns.handle_agent_callback/1
      )

    case callback_fun.(payload) do
      {:ok, _agent_run} -> :ok
      {:error, reason} -> Logger.error("failed to record agent run result: #{inspect(reason)}")
    end

    payload["status"]
  end
end
