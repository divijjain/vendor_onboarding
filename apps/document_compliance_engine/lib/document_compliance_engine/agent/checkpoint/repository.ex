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

  @doc "Removes any existing checkpoint for a thread_id, if one exists."
  @spec delete_by_thread_id(String.t()) :: :ok
  def delete_by_thread_id(thread_id) do
    RunCheckpoint
    |> where([c], c.thread_id == ^thread_id)
    |> Repo.delete_all()

    :ok
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

  @doc """
  Drops a finished checkpoint's payload, keeping the row as a record that
  the pause happened. Deliberately called *after* a resumed run finishes,
  never before: a crash between deserializing and finishing would
  otherwise leave a paused run with nothing to resume from.
  """
  @spec purge_payload(RunCheckpoint.t()) ::
          {:ok, RunCheckpoint.t()} | {:error, Ecto.Changeset.t()}
  def purge_payload(checkpoint) do
    checkpoint
    |> RunCheckpoint.purge_changeset()
    |> Repo.update()
  end

  @spec mark_resumed(RunCheckpoint.t()) :: {:ok, RunCheckpoint.t()} | {:error, Ecto.Changeset.t()}
  def mark_resumed(checkpoint) do
    checkpoint
    |> RunCheckpoint.status_changeset(:resumed)
    |> Repo.update()
  end
end
