defmodule DocumentComplianceEngine.DocumentJobs.Repository do
  @moduledoc """
  The only module that touches `DocumentComplianceEngine.Repo` for the `document_jobs`
  table. No coordination, no HTTP calls, no reaching into `AgentRuns`.
  """

  import Ecto.Query

  alias DocumentComplianceEngine.Repo
  alias DocumentComplianceEngine.DocumentJobs.Schema.DocumentJob

  @spec get_by_idempotency_key(String.t()) :: DocumentJob.t() | nil
  def get_by_idempotency_key(idempotency_key) do
    Repo.get_by(DocumentJob, idempotency_key: idempotency_key)
  end

  @spec insert(map()) :: {:ok, DocumentJob.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %DocumentJob{}
    |> DocumentJob.ingest_changeset(attrs)
    |> Repo.insert()
  end

  @spec get(pos_integer()) :: {:ok, DocumentJob.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(DocumentJob, id) do
      nil -> {:error, :not_found}
      document_job -> {:ok, document_job}
    end
  end

  @spec get!(pos_integer()) :: DocumentJob.t()
  def get!(id), do: Repo.get!(DocumentJob, id)

  @spec update_status(pos_integer(), atom()) ::
          {:ok, DocumentJob.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_status(id, status) do
    with {:ok, document_job} <- get(id) do
      document_job
      |> DocumentJob.status_changeset(status)
      |> Repo.update()
    end
  end

  @spec list(keyword()) :: [DocumentJob.t()]
  def list(opts \\ []) do
    status = Keyword.get(opts, :status)
    document_type_slug = Keyword.get(opts, :document_type_slug)
    limit = Keyword.get(opts, :limit, 50)

    DocumentJob
    |> maybe_filter_status(status)
    |> maybe_filter_document_type(document_type_slug)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, status: ^status)

  defp maybe_filter_document_type(query, nil), do: query

  defp maybe_filter_document_type(query, document_type_slug),
    do: where(query, document_type_slug: ^document_type_slug)
end
