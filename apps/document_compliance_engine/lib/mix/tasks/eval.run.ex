defmodule Mix.Tasks.Eval.Run do
  @shortdoc "Runs the two-tier eval harness against the agent pipeline"

  @moduledoc """
  Runs every synthetic fixture across every document type
  (`vendor_contract_w9` and `invoice` — see `Evals.Fixtures`) through the
  agent pipeline and prints a per-fixture table plus per-document-type,
  per-bucket decision accuracy.

  Needs OPENAI_API_KEY for the agents. The LLM-judge tier additionally
  needs ANTHROPIC_API_KEY and is skipped without it.

      mix eval.run
  """

  use Mix.Task

  alias DocumentComplianceEngine.Agent.Evals.Run

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    ensure_openai_key!()

    results = Run.run_all()

    print_table(results)
    print_buckets(results)
    print_judge(results)
  end

  # Without this the agents fail per-fixture with an opaque adapter error
  # and every bucket reports 0/N, which reads like a broken pipeline
  # rather than a missing key.
  defp ensure_openai_key! do
    if System.get_env("OPENAI_API_KEY") in [nil, ""] do
      Mix.raise("""
      OPENAI_API_KEY is not set — the extraction and entity-match agents cannot run.

      Set it in your environment (see the README) then re-run `mix eval.run`.
      The LLM-judge tier additionally needs ANTHROPIC_API_KEY (it is skipped without one).
      """)
    end
  end

  defp print_table(results) do
    IO.puts(
      String.pad_trailing("fixture", 22) <>
        String.pad_trailing("type", 22) <>
        String.pad_trailing("bucket", 24) <>
        String.pad_trailing("decision", 14) <>
        String.pad_trailing("expected", 14) <>
        String.pad_trailing("entity_match", 14) <>
        String.pad_trailing("tax_id_ok", 11) <>
        String.pad_trailing("grounded", 10) <> "error"
    )

    Enum.each(results, fn r ->
      IO.puts(
        String.pad_trailing(r.fixture.id, 22) <>
          String.pad_trailing(r.fixture.document_type_slug, 22) <>
          String.pad_trailing(r.fixture.bucket, 24) <>
          String.pad_trailing(to_string(r.decision), 14) <>
          String.pad_trailing(r.fixture.expected_decision, 14) <>
          String.pad_trailing(inspect(r.entity_match), 14) <>
          String.pad_trailing(inspect(r.tax_id_verbatim_ok), 11) <>
          String.pad_trailing(inspect(r.fields_grounded), 10) <> truncate(r.error)
      )
    end)
  end

  # Reactor wraps step failures in deeply nested structs; the table needs
  # the gist, not the whole tree.
  defp truncate(nil), do: ""

  defp truncate(error) when byte_size(error) > 120 do
    String.slice(error, 0, 120) <> "..."
  end

  defp truncate(error), do: error

  defp print_buckets(results) do
    IO.puts("")

    results
    |> Run.bucket_accuracy()
    |> Enum.sort()
    |> Enum.each(fn {{slug, bucket}, %{total: total, correct: correct}} ->
      IO.puts("#{slug}/#{bucket}: decision correct #{correct}/#{total}")
    end)
  end

  defp print_judge(results) do
    IO.puts("")

    if System.get_env("ANTHROPIC_API_KEY") in [nil, ""] do
      IO.puts("ANTHROPIC_API_KEY not set -- skipping LLM-judge tier.")
    else
      IO.puts("--- LLM-judge tier (Claude Sonnet) ---")

      results
      |> Run.judge_scores()
      |> Enum.each(fn {name, %{scores: scores, errors: errors}} ->
        error_note =
          if errors == [],
            do: "",
            else: " -- #{length(errors)} judge call(s) FAILED: #{inspect(Enum.take(errors, 3))}"

        case scores do
          [] when errors == [] ->
            IO.puts("#{name}: no scored cases")

          [] ->
            IO.puts("#{name}: all judge calls failed#{error_note}")

          _ ->
            avg = Enum.sum(scores) / length(scores)

            IO.puts(
              "#{name}: avg #{:erlang.float_to_binary(avg, decimals: 2)} (n=#{length(scores)})#{error_note}"
            )
        end
      end)
    end
  end
end
