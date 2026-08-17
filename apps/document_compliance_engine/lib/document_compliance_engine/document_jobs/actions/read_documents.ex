defmodule DocumentComplianceEngine.DocumentJobs.Actions.ReadDocuments do
  @moduledoc """
  Reads a document_job's stored documents back via `Storage`, for display
  (e.g. `ReviewLive`'s "original documents" section) — not for the agent
  pipeline, which reads `document_paths` directly (see `Agent.Run`).
  Best-effort: a role whose file can't be read (moved, deleted, or a test
  fixture inserted with no real file) is silently skipped rather than
  failing the whole read, since this is supplementary display, not the
  source of truth. Called only via `DocumentComplianceEngine.DocumentJobs.read_documents/1`.
  """

  alias DocumentComplianceEngine.DocumentJobs.Schema.DocumentJob
  alias DocumentComplianceEngine.Storage

  @spec call(DocumentJob.t()) :: [{String.t(), String.t()}]
  def call(%DocumentJob{document_paths: document_paths}) do
    document_paths
    |> Enum.flat_map(fn {role, path} ->
      case Storage.read(path) do
        {:ok, content} -> [{role, content}]
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(fn {role, _content} -> role end)
  end
end
