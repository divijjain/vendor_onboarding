defmodule DocumentComplianceEngine.Agent.Checkpoint.Repository do
  @moduledoc """
  The only module that calls `Repo.*` for `run_checkpoints` — mirrors the
  Phoenix app's repository convention (PRINCIPLES.md).
  """

  import Ecto.Query

  alias DocumentComplianceEngine.Agent.Checkpoint.Schema.RunCheckpoint
  alias DocumentComplianceEngine.Repo

  @spec insert(map()) :: {:ok, RunCheckpoint.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %RunCheckpoint{}
    |> RunCheckpoint.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec get_by_thread_id(String.t()) :: {:ok, RunCheckpoint.t()} | {:error, :not_found}
  def get_by_thread_id(thread_id) do
    RunCheckpoint
    |> where([c], c.thread_id == ^thread_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      checkpoint -> {:ok, checkpoint}
    end
  end

  @spec mark_resumed(RunCheckpoint.t()) :: {:ok, RunCheckpoint.t()} | {:error, Ecto.Changeset.t()}
  def mark_resumed(checkpoint) do
    checkpoint
    |> RunCheckpoint.status_changeset(:resumed)
    |> Repo.update()
  end
end
