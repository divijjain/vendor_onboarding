defmodule DocumentComplianceEngine.AgentRuns.AuditSamples.Repository do
  @moduledoc """
  The only module that touches `DocumentComplianceEngine.Repo` for the
  `audit_samples` table.
  """

  import Ecto.Query

  alias DocumentComplianceEngine.Repo
  alias DocumentComplianceEngine.AgentRuns.AuditSamples.Schema.AuditSample

  @spec insert(map()) :: {:ok, AuditSample.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %AuditSample{}
    |> AuditSample.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec get(pos_integer()) :: {:ok, AuditSample.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(AuditSample, id) do
      nil -> {:error, :not_found}
      audit_sample -> {:ok, audit_sample}
    end
  end

  @spec update_review(AuditSample.t(), map()) ::
          {:ok, AuditSample.t()} | {:error, Ecto.Changeset.t()}
  def update_review(%AuditSample{} = audit_sample, attrs) do
    audit_sample
    |> AuditSample.review_changeset(attrs)
    |> Repo.update()
  end

  @doc "Oldest-first — the audit queue works through the backlog in the order it was sampled."
  @spec list_pending() :: [AuditSample.t()]
  def list_pending do
    AuditSample
    |> where(status: :pending)
    |> order_by(asc: :inserted_at, asc: :id)
    |> Repo.all()
  end

  @doc "Owner-scoping happens by restricting to `document_job_ids` — see `AgentRuns.Actions.ListReviewedAudits`."
  @spec list_reviewed([pos_integer()], non_neg_integer()) :: [AuditSample.t()]
  def list_reviewed(document_job_ids, limit \\ 20) do
    AuditSample
    |> where([a], a.status != :pending and a.document_job_id in ^document_job_ids)
    |> order_by(desc: :reviewed_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end
end
