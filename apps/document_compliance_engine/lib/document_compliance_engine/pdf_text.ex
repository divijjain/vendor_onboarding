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

  **Scanned/image-only input** (a PDF with no text layer, or a raw photo/
  screenshot upload) used to be this module's one open gap — `pdftotext`
  finds nothing on a page with no text layer, and a raw JPEG/PNG isn't
  text at all, so either used to reach the extraction prompt as garbage
  or empty input. Closed via vision transcription: a PDF whose `pdftotext`
  output comes back empty/near-empty is rasterized page-by-page
  (`pdftoppm`, the same poppler-utils dependency already required — no
  new system dependency) and each page image is transcribed by a
  vision-capable LLM call; a raw JPEG/PNG (detected by its own magic
  header) skips straight to that same transcription step. Either way the
  *output* is still plain text, so nothing downstream — extraction,
  groundedness checking, confidence scoring — needs to know or care
  whether a document's text came from a text layer, OCR, or a vision
  model reading a photo. The transcription prompt explicitly forbids
  guessing at illegible text (`[illegible]` instead) for the same reason
  the extraction prompt forbids guessing at absent fields — a transcript
  that invents text would poison the groundedness check built on top of
  it, silently.
  """

  require Logger

  @not_enough_text_chars 20

  @spec extract(binary()) :: {:ok, String.t()} | {:error, term()}
  def extract(<<"%PDF-", _::binary>> = bytes), do: pdf_to_text(bytes)
  def extract(<<0xFF, 0xD8, 0xFF, _::binary>> = bytes), do: vision_transcribe(bytes, "image/jpeg")

  def extract(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>> = bytes),
    do: vision_transcribe(bytes, "image/png")

  def extract(bytes) when is_binary(bytes), do: {:ok, bytes}

  @doc """
  Sniffs a document's MIME type from the same magic numbers `extract/1`
  routes on — kept here, beside those clauses, so the byte-header table
  lives in exactly one place and can't drift from what conversion
  actually recognizes. For serving stored bytes back to a browser
  (`DocumentJobs.Actions.ReadRawDocument`), where the stored `.pdf`
  extension is meaningless.

  Note the deliberate asymmetry with `extract/1`: unknown bytes are
  *text* as far as conversion is concerned, but serving them is a
  different risk. Returning `:error` here forces the caller to decide,
  rather than handing an unrecognized attacker-supplied blob an inline,
  browser-sniffable content type.
  """
  @spec content_type(binary()) :: {:ok, String.t()} | :error
  def content_type(<<"%PDF-", _::binary>>), do: {:ok, "application/pdf"}
  def content_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}

  def content_type(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: {:ok, "image/png"}

  def content_type(bytes) when is_binary(bytes), do: :error

  defp pdf_to_text(bytes) do
    fun =
      Application.get_env(:document_compliance_engine, :agent_pdf_to_text_fun, &run_pdftotext/1)

    with {:ok, text} <- fun.(bytes) do
      if meaningful_text?(text) do
        {:ok, text}
      else
        Logger.info("pdftotext found no text layer — falling back to vision transcription")
        pdf_vision_transcribe(bytes)
      end
    end
  end

  defp meaningful_text?(text) do
    text
    |> String.replace(~r/[\s\f]/u, "")
    |> String.length()
    |> Kernel.>=(@not_enough_text_chars)
  end

  defp pdf_vision_transcribe(bytes) do
    fun =
      Application.get_env(:document_compliance_engine, :agent_pdf_to_images_fun, &run_pdftoppm/1)

    with {:ok, images} <- fun.(bytes) do
      transcribe_pages(images)
    end
  end

  defp transcribe_pages(images) do
    images
    |> Enum.reduce_while({:ok, []}, fn image_bytes, {:ok, acc} ->
      case vision_transcribe(image_bytes, "image/png") do
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, texts |> Enum.reverse() |> Enum.join("\n\f\n")}
      error -> error
    end
  end

  defp vision_transcribe(image_bytes, mime_type) do
    fun =
      Application.get_env(
        :document_compliance_engine,
        :agent_vision_transcribe_fun,
        &run_vision_transcribe/2
      )

    fun.(image_bytes, mime_type)
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

  # 150 DPI: legible enough for a vision model to read body text without
  # inflating the image (and so the request) past what's needed.
  defp run_pdftoppm(bytes) do
    if System.find_executable("pdftoppm") do
      unique = System.unique_integer([:positive])
      pdf_path = Path.join(System.tmp_dir!(), "pdf_vision-#{unique}.pdf")
      out_prefix = Path.join(System.tmp_dir!(), "pdf_vision-#{unique}")

      File.write!(pdf_path, bytes)

      result =
        case System.cmd("pdftoppm", ["-png", "-r", "150", pdf_path, out_prefix],
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            images =
              (out_prefix <> "*.png")
              |> Path.wildcard()
              |> Enum.sort()
              |> Enum.map(&File.read!/1)

            {:ok, images}

          {output, status} ->
            Logger.error("pdftoppm exited #{status}: #{output}")
            {:error, {:pdf_rasterize_failed, output}}
        end

      File.rm(pdf_path)
      (out_prefix <> "*.png") |> Path.wildcard() |> Enum.each(&File.rm/1)

      result
    else
      {:error, :pdftoppm_not_installed}
    end
  end

  @vision_prompt """
  Transcribe every piece of text visible in this image, verbatim and in
  reading order. Preserve line breaks where they help keep field labels
  aligned with their values, as in a form. Output only the transcribed
  text, nothing else — no summary, no commentary. If a word or section is
  illegible, write [illegible] in its place — never guess at text you
  cannot actually read.
  """

  defp run_vision_transcribe(image_bytes, mime_type) do
    data_url = "data:#{mime_type};base64,#{Base.encode64(image_bytes)}"

    case Instructor.chat_completion(
           model: "gpt-4o-mini",
           response_model: %{text: :string},
           max_retries: 1,
           messages: [
             %{
               role: "user",
               content: [
                 %{type: "text", text: @vision_prompt},
                 %{type: "image_url", image_url: %{url: data_url}}
               ]
             }
           ]
         ) do
      {:ok, %{text: text}} -> {:ok, text}
      error -> error
    end
  end
end
