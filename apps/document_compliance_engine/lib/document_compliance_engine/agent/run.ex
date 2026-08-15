defmodule DocumentComplianceEngine.Agent.Run do
  @moduledoc """
  Drives `OnboardingReactor` and reports its outcome directly to the
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
  alias DocumentComplianceEngine.Agent.OnboardingReactor
  alias DocumentComplianceEngine.AgentRuns

  @spec trigger(pos_integer(), map()) :: :ok
  def trigger(document_job_id, document_paths) do
    with {:ok, contract_text} <- read_document(document_paths, "contract"),
         {:ok, w9_text} <- read_document(document_paths, "w9") do
      inputs = %{contract_text: contract_text, w9_text: w9_text, human_decision: nil}

      OnboardingReactor
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

  defp resume_inputs(checkpoint, decision) do
    %{
      contract_text: checkpoint.inputs["contract_text"],
      w9_text: checkpoint.inputs["w9_text"],
      human_decision: decision
    }
  end

  defp handle_result({:ok, result}, document_job_id, _inputs) do
    report(%{
      "document_job_id" => document_job_id,
      "status" => result.status,
      "company_name" => result.contract.company_name,
      "w9_company_name" => result.w9.company_name,
      "tax_id" => result.w9.tax_id,
      "payment_terms" => result.contract.payment_terms,
      "liability_clauses" => result.contract.liability_clauses
    })
  end

  defp handle_result({:halted, reactor}, document_job_id, inputs) do
    {contract, w9, explanation} = halted_details(reactor)

    Repository.insert(%{
      thread_id: thread_id_for(document_job_id),
      document_job_id: document_job_id,
      reactor_state: :erlang.term_to_binary(reactor),
      inputs: %{"contract_text" => inputs.contract_text, "w9_text" => inputs.w9_text},
      explanation: explanation
    })

    report(%{
      "document_job_id" => document_job_id,
      "status" => "needs_review",
      "thread_id" => thread_id_for(document_job_id),
      "explanation" => explanation,
      "company_name" => contract && contract.company_name,
      "w9_company_name" => w9 && w9.company_name,
      "tax_id" => w9 && w9.tax_id,
      "payment_terms" => contract && contract.payment_terms,
      "liability_clauses" => contract && contract.liability_clauses
    })
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

    {results[:extract_contract], results[:extract_w9], explanation}
  end

  @spec thread_id_for(pos_integer()) :: String.t()
  def thread_id_for(document_job_id), do: "document_job-#{document_job_id}"

  defp read_document(document_paths, key) do
    case document_paths[key] do
      nil -> {:error, "missing document path: #{key}"}
      path -> File.read(path)
    end
  end

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
