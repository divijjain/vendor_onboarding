defmodule DocumentComplianceEngine.DocumentJobs.Actions.ReadRawDocument do
  @moduledoc """
  Reads one stored document back as its **original bytes**, for serving to
  a reviewer's browser (`DocumentComplianceEngineWeb.DocumentController`).

  The sibling `ReadDocuments` converts through `PdfText` to plain text; this
  one deliberately does not. A human approving a compliance decision needs
  the document itself, not the pipeline's reading of it — for a scanned
  page that text is an LLM vision transcript, so showing only the transcript
  asks the reviewer to check the agent's work using the agent's own output
  as the evidence.

  `role` arrives from request params, so it's looked up as a **map key** in
  `document_paths` and never joined into a path — an unknown role is
  `{:error, :not_found}`, and there's no traversal surface. The stored `.pdf`
  extension is meaningless (`IngestWebhook` writes every file with it), so
  the type comes from `PdfText.content_type/1` sniffing the real bytes;
  `:unknown` is passed through for the caller to downgrade rather than
  guessed at here.

  Called only via `DocumentComplianceEngine.DocumentJobs.read_raw_document/2`.
  """

  alias DocumentComplianceEngine.DocumentJobs.Schema.DocumentJob
  alias DocumentComplianceEngine.{PdfText, Storage}

  @spec call(DocumentJob.t(), String.t()) ::
          {:ok, {binary(), String.t() | :unknown}} | {:error, :not_found | term()}
  def call(%DocumentJob{document_paths: document_paths}, role) do
    with {:ok, path} <- fetch_path(document_paths, role),
         {:ok, bytes} <- Storage.read(path) do
      {:ok, {bytes, content_type(bytes)}}
    end
  end

  defp fetch_path(document_paths, role) do
    case Map.fetch(document_paths, role) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, :not_found}
    end
  end

  defp content_type(bytes) do
    case PdfText.content_type(bytes) do
      {:ok, content_type} -> content_type
      :error -> :unknown
    end
  end
end
