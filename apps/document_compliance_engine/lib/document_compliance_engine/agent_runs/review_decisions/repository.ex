defmodule DocumentComplianceEngine.AgentRuns.ReviewDecisions.Repository do
  @moduledoc """
  The only module that touches `DocumentComplianceEngine.Repo` for the
  `review_decisions` table. Insert and read only, by design — an audit
  record must never be altered after the fact, so no update/delete
  function exists here.
  """

  import Ecto.Query

  alias DocumentComplianceEngine.Repo
  alias DocumentComplianceEngine.AgentRuns.ReviewDecisions.Schema.ReviewDecision

  @spec insert(map()) :: {:ok, ReviewDecision.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %ReviewDecision{}
    |> ReviewDecision.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec list_for_document_job(pos_integer()) :: [ReviewDecision.t()]
  def list_for_document_job(document_job_id) do
    ReviewDecision
    |> where(document_job_id: ^document_job_id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> Repo.all()
  end
end
