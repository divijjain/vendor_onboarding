defmodule DocumentComplianceEngine.DocumentJobs.Actions.ReadDocuments do
  @moduledoc """
  Reads a document_job's stored documents back via `Storage`, run through
  `PdfText` the same way the agent pipeline does, for display (e.g.
  `ReviewLive`'s "original documents" section) — not for the pipeline
  itself, which reads `document_paths` directly (see `Agent.Run`). Without
  the `PdfText` step this used to dump a PDF's raw binary bytes straight
  into the page (caught live, not in a test — see CONTEXT.md's dated
  entry). Best-effort: a role whose file can't be read, or can't be
  converted (moved, deleted, a test fixture inserted with no real file, or
  `pdftotext` failing on a malformed PDF), is silently skipped rather than
  failing the whole read, since this is supplementary display, not the
  source of truth. Called only via `DocumentComplianceEngine.DocumentJobs.read_documents/1`.
  """

  alias DocumentComplianceEngine.DocumentJobs.Schema.DocumentJob
  alias DocumentComplianceEngine.{PdfText, Storage}

  @spec call(DocumentJob.t()) :: [{String.t(), String.t()}]
  def call(%DocumentJob{document_paths: document_paths}) do
    document_paths
    |> Enum.flat_map(fn {role, path} ->
      with {:ok, bytes} <- Storage.read(path),
           {:ok, text} <- PdfText.extract(bytes) do
        [{role, text}]
      else
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(fn {role, _content} -> role end)
  end
end
