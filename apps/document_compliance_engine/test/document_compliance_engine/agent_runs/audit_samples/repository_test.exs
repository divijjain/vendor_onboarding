defmodule DocumentComplianceEngine.AgentRuns.AuditSamples.RepositoryTest do
  use DocumentComplianceEngine.DataCase, async: true

  alias DocumentComplianceEngine.AgentRuns.AuditSamples.Repository

  test "insert/1 requires document_job_id, agent_run_id, and status" do
    assert {:ok, sample} =
             Repository.insert(%{document_job_id: 1, agent_run_id: 1, status: :pending})

    assert sample.status == :pending
    assert {:error, changeset} = Repository.insert(%{})
    assert %{document_job_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "insert/1 enforces one sample per agent_run_id" do
    assert {:ok, _} = Repository.insert(%{document_job_id: 1, agent_run_id: 42, status: :pending})

    assert {:error, changeset} =
             Repository.insert(%{document_job_id: 2, agent_run_id: 42, status: :pending})

    assert %{agent_run_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "list_pending/0 returns only :pending samples, oldest first" do
    {:ok, first} = Repository.insert(%{document_job_id: 1, agent_run_id: 1, status: :pending})
    {:ok, second} = Repository.insert(%{document_job_id: 2, agent_run_id: 2, status: :pending})
    {:ok, reviewed} = Repository.insert(%{document_job_id: 3, agent_run_id: 3, status: :pending})

    {:ok, _} =
      Repository.update_review(reviewed, %{
        status: :confirmed,
        reviewer: "Jane",
        reviewed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert Enum.map(Repository.list_pending(), & &1.id) == [first.id, second.id]
  end

  test "list_reviewed/2 returns only non-pending samples restricted to the given document_job_ids, most recently reviewed first" do
    {:ok, pending} = Repository.insert(%{document_job_id: 1, agent_run_id: 1, status: :pending})

    {:ok, confirmed} =
      Repository.insert(%{document_job_id: 2, agent_run_id: 2, status: :pending})

    {:ok, confirmed} =
      Repository.update_review(confirmed, %{
        status: :confirmed,
        reviewer: "Jane",
        reviewed_at: ~U[2026-01-01 00:00:00Z]
      })

    {:ok, discrepancy} =
      Repository.insert(%{document_job_id: 3, agent_run_id: 3, status: :pending})

    {:ok, discrepancy} =
      Repository.update_review(discrepancy, %{
        status: :discrepancy,
        reviewer: "Jane",
        reviewed_at: ~U[2026-01-02 00:00:00Z]
      })

    # A reviewed sample for a document_job_id (4) outside the requested set
    # must not appear, even though it's otherwise reviewed.
    {:ok, other_owners} =
      Repository.insert(%{document_job_id: 4, agent_run_id: 4, status: :pending})

    {:ok, _other_owners} =
      Repository.update_review(other_owners, %{
        status: :confirmed,
        reviewer: "Someone else",
        reviewed_at: ~U[2026-01-03 00:00:00Z]
      })

    reviewed_ids = Repository.list_reviewed([1, 2, 3]) |> Enum.map(& &1.id)
    assert reviewed_ids == [discrepancy.id, confirmed.id]
    refute pending.id in reviewed_ids
    refute other_owners.id in reviewed_ids
  end

  test "get/1 returns {:error, :not_found} for a missing id" do
    assert {:error, :not_found} = Repository.get(-1)
  end
end
