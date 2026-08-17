defmodule DocumentComplianceEngine.Agent.Evals.Judge do
  @moduledoc """
  LLM-as-judge tier, hand-rolled on Anthropic's Messages API.

  Deliberately a different provider than the GPT-4o-mini agents it grades
  — CONTEXT.md's anti-self-grading decision. Replaces DeepEval's `GEval`
  (Python-only) while scoring the same two criteria; each call asks for a
  strict JSON verdict and validates the score is in range, so a malformed
  judge response is an error rather than a silently-wrong number.

  Requires ANTHROPIC_API_KEY. The deterministic tier runs without it.
  """

  @model "claude-sonnet-5"
  @api_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"

  @entity_match_criteria """
  You are grading whether an extraction agent correctly judged if two company \
  names refer to the same legal entity. Formatting differences (abbreviations, \
  punctuation, a missing or added legal suffix like "Corp" vs "Corporation") \
  still count as the SAME entity. A genuinely different vendor name does not.

  Score 1.0 if the agent's judgment matches the expected judgment, 0.0 if it \
  does not.
  """

  @groundedness_criteria """
  You are grading whether an agent's drafted explanation of a validation \
  discrepancy is grounded in the actual findings it was given. Score 1.0 if \
  every claim in the explanation is supported by the findings, lower it toward \
  0.0 as the explanation invents facts not present in the findings.
  """

  @doc "Scores entity-match correctness under formatting variation."
  @spec entity_match(String.t(), String.t(), boolean(), boolean()) ::
          {:ok, %{score: float(), reasoning: String.t()}} | {:error, term()}
  def entity_match(contract_text, w9_text, actual_match, expected_match) do
    score(@entity_match_criteria, """
    Contract document:
    #{contract_text}

    W-9 document:
    #{w9_text}

    The agent judged: same entity = #{actual_match}
    Correct answer:   same entity = #{expected_match}
    """)
  end

  @doc "Scores whether a drafted explanation is grounded in the real findings."
  @spec groundedness(String.t(), String.t()) ::
          {:ok, %{score: float(), reasoning: String.t()}} | {:error, term()}
  def groundedness(findings, explanation) do
    score(@groundedness_criteria, """
    Actual validation findings:
    #{findings}

    The agent's drafted explanation:
    #{explanation}
    """)
  end

  defp score(criteria, evidence) do
    case Application.get_env(:document_compliance_engine, :agent_judge_fun) do
      nil -> request(criteria, evidence)
      fun -> fun.(criteria, evidence)
    end
  end

  defp request(criteria, evidence) do
    prompt = """
    #{criteria}

    #{evidence}

    Respond with ONLY a JSON object, no prose, in exactly this form:
    {"score": <number between 0.0 and 1.0>, "reasoning": "<one sentence>"}
    """

    body = %{
      model: @model,
      max_tokens: 256,
      messages: [%{role: "user", content: prompt}]
    }

    with {:ok, api_key} <- api_key(),
         {:ok, %Req.Response{status: 200, body: response}} <- post(body, api_key),
         {:ok, text} <- extract_text(response),
         {:ok, verdict} <- decode_verdict(text) do
      {:ok, verdict}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:judge_http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post(body, api_key) do
    Req.post(@api_url,
      json: body,
      headers: [
        {"x-api-key", api_key},
        {"anthropic-version", @anthropic_version}
      ],
      receive_timeout: 60_000
    )
  end

  defp api_key do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> {:error, :missing_anthropic_api_key}
      "" -> {:error, :missing_anthropic_api_key}
      key -> {:ok, key}
    end
  end

  @doc """
  Finds the actual answer in an Anthropic Messages API response body. Not
  just the head of the `content` list: extended-thinking responses put a
  `type: "thinking"` block ahead of the `type: "text"` block, so the
  answer isn't reliably the first element — a real bug caught live by
  `Evals.Run.judge_scores/1` surfacing a judge failure instead of silently
  dropping it (see `CONTEXT.md`'s dated entry). Public so this parsing
  logic is directly testable without a live API call.
  """
  @spec extract_text(map()) :: {:ok, String.t()} | {:error, term()}
  def extract_text(%{"content" => content}) when is_list(content) do
    case Enum.find(content, &match?(%{"type" => "text"}, &1)) do
      %{"text" => text} -> {:ok, text}
      _ -> {:error, {:unexpected_judge_response, content}}
    end
  end

  def extract_text(other), do: {:error, {:unexpected_judge_response, other}}

  defp decode_verdict(text) do
    with {:ok, json} <- extract_json(text),
         {:ok, %{"score" => score} = decoded} when is_number(score) <- Jason.decode(json),
         true <- score >= 0.0 and score <= 1.0 do
      {:ok, %{score: score / 1, reasoning: decoded["reasoning"] || ""}}
    else
      _ -> {:error, {:invalid_judge_verdict, text}}
    end
  end

  # The model is asked for bare JSON, but tolerate it wrapping the object
  # in prose or a code fence rather than failing the whole eval run.
  defp extract_json(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> {:ok, json}
      nil -> {:error, :no_json_in_judge_response}
    end
  end
end
