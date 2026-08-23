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

  @doc """
  Unscoped — for trusted internal/cross-context callers that already have
  a legitimate `document_job_id` in hand (an Oban job's own args, another
  `AgentRuns` action continuing a flow a LiveView already authorized, the
  MCP tool server's separate trust boundary). Never call this with an id
  sourced from a web request's raw params — use `get/2` for that.
  """
  @spec get(pos_integer()) :: {:ok, DocumentJob.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(DocumentJob, id) do
      nil -> {:error, :not_found}
      document_job -> {:ok, document_job}
    end
  end

  @doc """
  Organization-scoped — this is the one place a document_job gets fetched
  by a guessable integer id straight from a web request
  (`/document_jobs/:id`), so a wrong organization must look exactly like
  a missing row, never a different error.
  """
  @spec get(pos_integer(), pos_integer()) :: {:ok, DocumentJob.t()} | {:error, :not_found}
  def get(id, organization_id) do
    case Repo.get_by(DocumentJob, id: id, organization_id: organization_id) do
      nil -> {:error, :not_found}
      document_job -> {:ok, document_job}
    end
  end

  @doc "Same organization-scoping as `get/2` — a wrong organization raises the same `Ecto.NoResultsError` as a missing id."
  @spec get!(pos_integer(), pos_integer()) :: DocumentJob.t()
  def get!(id, organization_id),
    do: Repo.get_by!(DocumentJob, id: id, organization_id: organization_id)

  @spec update_status(pos_integer(), atom()) ::
          {:ok, DocumentJob.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_status(id, status) do
    with {:ok, document_job} <- get(id) do
      document_job
      |> DocumentJob.status_changeset(status)
      |> Repo.update()
    end
  end

  @doc "Batched fetch by primary key, for merging into a list read model without an N+1. Not owner-scoped — only ever called on an already-owner-filtered id list."
  @spec get_by_ids([pos_integer()]) :: %{pos_integer() => DocumentJob.t()}
  def get_by_ids(ids) do
    DocumentJob
    |> where([j], j.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc "Organization is a required positional argument, not a buried opt, so a call site can't accidentally forget to scope it."
  @spec list(pos_integer(), keyword()) :: [DocumentJob.t()]
  def list(organization_id, opts \\ []) do
    status = Keyword.get(opts, :status)
    document_type_slug = Keyword.get(opts, :document_type_slug)
    limit = Keyword.get(opts, :limit, 50)

    DocumentJob
    |> where(organization_id: ^organization_id)
    |> maybe_filter_status(status)
    |> maybe_filter_document_type(document_type_slug)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Every id belonging to this organization, unpaginated — for a downstream
  organization-scoped filter (e.g. `AgentRuns.Actions.ListReviewedAudits`)
  that needs the full set to filter another table by, not a page of
  `DocumentJob` structs. Bounded by construction: it's scoped to one
  organization's own activity, not a cross-account scan.
  """
  @spec list_ids_for_organization(pos_integer()) :: [pos_integer()]
  def list_ids_for_organization(organization_id) do
    DocumentJob
    |> where(organization_id: ^organization_id)
    |> select([j], j.id)
    |> Repo.all()
  end

  @doc """
  Bulk-fills `organization_id` for every one of this user's document_jobs
  that don't have one yet — a webhook can pre-provision an owner with no
  organization, leaving these rows orphaned until that person's first
  login creates or joins one. A single `update_all`, not N individual
  updates. Called only from `Organizations.Actions.JoinOrganization`.
  """
  @spec backfill_organization_id_for_owner(pos_integer(), pos_integer()) ::
          {non_neg_integer(), nil}
  def backfill_organization_id_for_owner(owner_user_id, organization_id) do
    DocumentJob
    |> where([j], j.owner_user_id == ^owner_user_id and is_nil(j.organization_id))
    |> Repo.update_all(
      set: [
        organization_id: organization_id,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      ]
    )
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, status: ^status)

  defp maybe_filter_document_type(query, nil), do: query

  defp maybe_filter_document_type(query, document_type_slug),
    do: where(query, document_type_slug: ^document_type_slug)
end
