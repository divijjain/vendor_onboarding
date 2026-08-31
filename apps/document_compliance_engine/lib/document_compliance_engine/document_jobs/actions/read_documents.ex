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

  Each entry also carries the document's sniffed `content_type`, so
  `ReviewLive` can pick the right viewer element (`<img>` vs `<iframe>`)
  for the bytes `DocumentController` will serve. It's derived from the same
  bytes already read here, so it costs no extra storage round-trip.
  """

  alias DocumentComplianceEngine.DocumentJobs.Schema.DocumentJob
  alias DocumentComplianceEngine.{PdfText, Storage}

  @type document :: %{role: String.t(), text: String.t(), content_type: String.t() | :unknown}

  @spec call(DocumentJob.t()) :: [document()]
  def call(%DocumentJob{document_paths: document_paths}) do
    document_paths
    |> Enum.flat_map(fn {role, path} ->
      with {:ok, bytes} <- Storage.read(path),
           {:ok, text} <- PdfText.extract(bytes) do
        [%{role: role, text: text, content_type: content_type(bytes)}]
      else
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(& &1.role)
  end

  defp content_type(bytes) do
    case PdfText.content_type(bytes) do
      {:ok, content_type} -> content_type
      :error -> :unknown
    end
  end
end
