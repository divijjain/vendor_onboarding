defmodule DocumentComplianceEngine.Agent.Evals.Classification do
  @moduledoc """
  The eval tier for `Agent.Classification`, and the only reason this
  project is allowed to state a confidence threshold as a number.

  It runs the **whole existing fixture corpus** with each fixture's
  `document_type_slug` withheld, against the **whole seeded registry** —
  so the classifier faces every document type as a candidate, not the one
  the fixture happens to be. Deterministic scoring, no judge: a fixture
  either got its own declared type back or it didn't, which is an
  objective right answer and exactly the kind this project refuses to
  spend an LLM judge on.

  The `invoice_wrong_type` bucket is scored the other way round on
  purpose: a résumé is *correctly* classified when the classifier declines
  to place it (or places it with confidence below the threshold). Those
  fixtures are the population the threshold exists to divert to a human,
  so they're the only evidence that a threshold is set anywhere useful —
  a corpus of documents that all belong to a type could justify any
  threshold at all.
  """

  alias DocumentComplianceEngine.Agent.Classification
  alias DocumentComplianceEngine.Agent.Evals.Fixtures
  alias DocumentComplianceEngine.DocumentTypes
  alias DocumentComplianceEngine.PdfText

  defmodule Result do
    @moduledoc "One fixture's classification outcome."
    defstruct [:fixture, :expected, :actual, :confidence, :source, :correct?, :confident?, :error]

    @type t :: %__MODULE__{}
  end

  @concurrency 5

  @doc """
  Classifies every fixture with its type withheld. `candidates` defaults
  to the live registry, which is the point — the classifier should have to
  tell six document types apart, not two.
  """
  @spec run_all(keyword()) :: [Result.t()]
  def run_all(opts \\ []) do
    candidates = Keyword.get_lazy(opts, :candidates, &registry_candidates/0)

    Fixtures.all()
    |> Task.async_stream(&run_fixture(&1, candidates),
      max_concurrency: Keyword.get(opts, :concurrency, @concurrency),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp registry_candidates, do: Classification.candidates(DocumentTypes.list_document_types())

  @spec run_fixture(Fixtures.Fixture.t(), [Classification.candidate()]) :: Result.t()
  def run_fixture(fixture, candidates) do
    with {:ok, documents} <- documents_for(fixture),
         # nil, deliberately: the whole measurement is what happens when
         # the caller doesn't say.
         {:ok, classification} <- Classification.classify(documents, candidates, nil) do
      expected = expected_slug(fixture)

      %Result{
        fixture: fixture,
        expected: expected,
        actual: classification.slug,
        confidence: classification.confidence,
        source: classification.source,
        confident?: classification.confident?,
        correct?: correct?(expected, classification)
      }
    else
      {:error, reason} -> %Result{fixture: fixture, error: inspect(reason)}
    end
  end

  # A wrong-type fixture has no correct document type — its expected
  # answer is "don't place this".
  defp expected_slug(%Fixtures.Fixture{bucket: "invoice_wrong_type"}), do: nil
  defp expected_slug(fixture), do: fixture.document_type_slug

  defp correct?(nil, classification), do: not classification.confident?

  defp correct?(expected, classification),
    do: classification.slug == expected and classification.confident?

  defp documents_for(%Fixtures.Fixture{image_paths: image_paths})
       when is_map(image_paths) and map_size(image_paths) > 0 do
    Enum.reduce_while(image_paths, {:ok, %{}}, fn {role, path}, {:ok, acc} ->
      with {:ok, bytes} <- File.read(path),
           {:ok, text} <- PdfText.extract(bytes) do
        {:cont, {:ok, Map.put(acc, role, text)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp documents_for(fixture), do: {:ok, fixture.documents}

  @doc "Accuracy per `{document_type_slug, bucket}`, same shape as `Evals.Run.bucket_accuracy/1`."
  @spec bucket_accuracy([Result.t()]) :: %{
          {String.t(), String.t()} => %{total: non_neg_integer(), correct: non_neg_integer()}
        }
  def bucket_accuracy(results) do
    results
    |> Enum.group_by(&{&1.fixture.document_type_slug, &1.fixture.bucket})
    |> Map.new(fn {key, group} ->
      {key, %{total: length(group), correct: Enum.count(group, & &1.correct?)}}
    end)
  end

  @doc """
  The numbers the threshold is set from, in the three populations that
  actually mean different things:

    - `placed` — fixtures given their own correct type. Their confidences
      are the floor the threshold must sit *below*.
    - `declined` — the wrong-type fixtures, correctly not placed. Their
      confidences are the ceiling it must sit *above*.
    - `wrong` — anything given a type that wasn't its own.

  Lumping `placed` and `declined` together (both are "correct") would hide
  the only gap that matters, since a correct decline is a *low*-confidence
  answer by definition.
  """
  @spec confidence_split([Result.t()]) :: %{
          placed: [float()],
          declined: [float()],
          wrong: [float()]
        }
  def confidence_split(results) do
    scored = Enum.filter(results, &is_nil(&1.error))

    %{
      placed: scored |> Enum.filter(&(&1.correct? and &1.actual)) |> Enum.map(& &1.confidence),
      declined:
        scored |> Enum.filter(&(&1.correct? and is_nil(&1.actual))) |> Enum.map(& &1.confidence),
      wrong: scored |> Enum.reject(& &1.correct?) |> Enum.map(& &1.confidence)
    }
  end

  @doc "How many fixtures each classification route resolved — the LLM-call saving."
  @spec source_counts([Result.t()]) :: %{atom() => non_neg_integer()}
  def source_counts(results) do
    results
    |> Enum.filter(&is_nil(&1.error))
    |> Enum.frequencies_by(& &1.source)
  end
end
