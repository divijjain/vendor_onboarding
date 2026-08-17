defmodule DocumentComplianceEngine.PdfText do
  @moduledoc """
  Converts a document's raw bytes into plain text — closes the gap
  CONTEXT.md flagged: stored document bytes used to be fed to the
  extraction LLM (and shown to a human reviewer) as if they were already
  clean text, with no fixture or test ever exercising a real PDF.

  Not namespaced under `Agent.*` even though the agent pipeline is its
  main caller — `DocumentJobs.Actions.ReadDocuments` (the "show the
  original documents" feature on `ReviewLive`) needs the exact same
  conversion for a human reader, and that context has no other dependency
  on the agent brain. Pure bytes in, bytes/text out — no filesystem
  coupling — so either caller can hand it whatever bytes `Storage` (or a
  direct `File.read/1`, for the pipeline's own long-standing bypass of
  that behaviour) already produced.

  PDFs are detected by the `%PDF-` magic-number header, not the file
  extension (`IngestWebhook` writes every stored file with a `.pdf`
  extension regardless of actual content), and run through `pdftotext`
  (poppler-utils, a system dependency; `brew install poppler` — see
  README's local dev setup) via a temp file, since `System.cmd/3` has no
  stdin-piping option. Anything else is assumed to already be plain text
  — every eval fixture, and a `.txt` upload — and returned as-is.

  Only handles PDFs with a real text layer. A scanned/image-only PDF would
  need OCR on top of this, which stays a separate, still-open gap.
  """

  require Logger

  @spec extract(binary()) :: {:ok, String.t()} | {:error, term()}
  def extract(<<"%PDF-", _::binary>> = bytes), do: pdf_to_text(bytes)
  def extract(bytes) when is_binary(bytes), do: {:ok, bytes}

  defp pdf_to_text(bytes) do
    fun =
      Application.get_env(:document_compliance_engine, :agent_pdf_to_text_fun, &run_pdftotext/1)

    fun.(bytes)
  end

  # -layout roughly preserves the source's spatial structure (columns,
  # field labels lining up with values), which matters for a form like a
  # W-9 more than plain reading-order text would.
  defp run_pdftotext(bytes) do
    if System.find_executable("pdftotext") do
      tmp_path =
        Path.join(System.tmp_dir!(), "pdf_text-#{System.unique_integer([:positive])}.pdf")

      File.write!(tmp_path, bytes)

      result =
        case System.cmd("pdftotext", ["-layout", tmp_path, "-"], stderr_to_stdout: true) do
          {text, 0} ->
            {:ok, text}

          {output, status} ->
            Logger.error("pdftotext exited #{status}: #{output}")
            {:error, {:pdf_extraction_failed, output}}
        end

      File.rm(tmp_path)
      result
    else
      {:error, :pdftotext_not_installed}
    end
  end
end
