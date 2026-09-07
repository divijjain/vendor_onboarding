defmodule Mix.Tasks.Eval.Classify do
  @shortdoc "Measures document-type classification accuracy across the fixture corpus"

  @moduledoc """
  Runs every fixture in `Evals.Fixtures` through `Agent.Classification`
  with its declared `document_type_slug` withheld, against every document
  type in the seeded registry, and reports accuracy, the confidence split
  between right and wrong answers, and how many fixtures were resolved
  without an LLM call at all.

  Needs OPENAI_API_KEY. No judge tier and so no ANTHROPIC_API_KEY: whether
  a document was classified as its own type is an objective fact, not a
  judgement call.

      mix eval.classify
      mix eval.classify --concurrency 2

  `--concurrency` bounds how many fixtures are classified at once (default
  5) — see `mix eval.run` on why the grown corpus needs it.
  """

  use Mix.Task

  alias DocumentComplianceEngine.Agent.Classification
  alias DocumentComplianceEngine.Agent.Evals.Classification, as: Evals

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    ensure_openai_key!()

    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [concurrency: :integer])
    results = Evals.run_all(Keyword.take(opts, [:concurrency]))

    print_table(results)
    print_buckets(results)
    print_confidence(results)
    print_sources(results)
  end

  defp ensure_openai_key! do
    if System.get_env("OPENAI_API_KEY") in [nil, ""] do
      Mix.raise("OPENAI_API_KEY is not set — the classifier cannot run.")
    end
  end

  defp print_table(results) do
    IO.puts(
      String.pad_trailing("fixture", 30) <>
        String.pad_trailing("expected", 22) <>
        String.pad_trailing("classified", 22) <>
        String.pad_trailing("conf", 7) <>
        String.pad_trailing("via", 15) <> "ok"
    )

    Enum.each(results, fn r ->
      IO.puts(
        String.pad_trailing(r.fixture.id, 30) <>
          String.pad_trailing(to_string(r.expected || "(none)"), 22) <>
          String.pad_trailing(to_string(r.actual || "(none)"), 22) <>
          String.pad_trailing(fmt(r.confidence), 7) <>
          String.pad_trailing(to_string(r.source || "-"), 15) <>
          if(r.error, do: "ERROR #{r.error}", else: if(r.correct?, do: "yes", else: "NO"))
      )
    end)
  end

  defp print_buckets(results) do
    IO.puts("")

    # Buckets count only fixtures that produced an answer, for the same reason.
    results
    |> Enum.reject(& &1.error)
    |> Evals.bucket_accuracy()
    |> Enum.sort()
    |> Enum.each(fn {{slug, bucket}, %{total: total, correct: correct}} ->
      IO.puts("#{slug}/#{bucket}: classified correctly #{correct}/#{total}")
    end)

    {errored, scored} = Enum.split_with(results, & &1.error)
    correct = Enum.count(scored, & &1.correct?)

    IO.puts("\nOverall: #{correct}/#{length(scored)} classified")

    # Kept out of the accuracy number rather than counted as wrong answers:
    # a fixture the API refused to look at has no classification to be
    # right or wrong about, and folding the two together reads as five
    # misclassifications when it is five rate-limit refusals.
    if errored != [] do
      IO.puts("#{length(errored)} fixture(s) errored and are excluded from that number:")

      for r <- errored do
        IO.puts("  #{r.fixture.id}: #{truncate(r.error)}")
      end
    end
  end

  defp truncate(error) when byte_size(error) > 100, do: String.slice(error, 0, 100) <> "..."
  defp truncate(error), do: error

  defp print_confidence(results) do
    IO.puts("")
    IO.puts("--- Confidence split (threshold #{fmt(Classification.confidence_threshold())}) ---")

    %{placed: placed, declined: declined, wrong: wrong} = Evals.confidence_split(results)

    print_stats("placed (correct type)", placed)
    print_stats("declined (correctly unplaced)", declined)
    print_stats("wrong", wrong)
  end

  defp print_stats(_label, []), do: IO.puts("  (none)")

  defp print_stats(label, confidences) do
    sorted = Enum.sort(confidences)

    IO.puts(
      "  #{label}: n=#{length(confidences)} min=#{fmt(hd(sorted))} " <>
        "max=#{fmt(List.last(sorted))} avg=#{fmt(Enum.sum(confidences) / length(confidences))}"
    )
  end

  defp print_sources(results) do
    IO.puts("")
    IO.puts("--- Resolved by ---")

    results
    |> Evals.source_counts()
    |> Enum.sort()
    |> Enum.each(fn {source, count} -> IO.puts("  #{source}: #{count}") end)
  end

  defp fmt(nil), do: "-"
  defp fmt(number), do: :erlang.float_to_binary(number * 1.0, decimals: 2)
end
