defmodule DocumentComplianceEngine.PdfTextTest do
  use ExUnit.Case, async: true

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.PdfText

  test "non-PDF bytes are returned as-is, without touching the pdf_to_text seam" do
    assert PdfText.extract("VENDOR SERVICES AGREEMENT with Acme Corp.") ==
             {:ok, "VENDOR SERVICES AGREEMENT with Acme Corp."}
  end

  test "%PDF- prefixed bytes are routed through the injected pdf_to_text function" do
    stub(pdf_to_text_fun: fn bytes -> {:ok, "extracted from #{byte_size(bytes)} bytes"} end)

    pdf_bytes = "%PDF-1.4\nnot a real PDF body, just needs the magic header"

    assert PdfText.extract(pdf_bytes) == {:ok, "extracted from #{byte_size(pdf_bytes)} bytes"}
  end

  test "propagates a pdf_to_text error instead of swallowing it" do
    stub(pdf_to_text_fun: fn _bytes -> {:error, :pdftotext_not_installed} end)

    assert PdfText.extract("%PDF-1.4\nnot a real PDF body") ==
             {:error, :pdftotext_not_installed}
  end

  describe "scanned/image-only input" do
    test "a JPEG upload is routed straight to vision transcription" do
      test_pid = self()

      stub(
        vision_transcribe_fun: fn image_bytes, mime_type ->
          send(test_pid, {:transcribed, image_bytes, mime_type})
          {:ok, "transcribed jpeg text"}
        end
      )

      jpeg_bytes = <<0xFF, 0xD8, 0xFF, 0xE0, "not a real jpeg body">>

      assert PdfText.extract(jpeg_bytes) == {:ok, "transcribed jpeg text"}
      assert_received {:transcribed, ^jpeg_bytes, "image/jpeg"}
    end

    test "a PNG upload is routed straight to vision transcription" do
      stub(vision_transcribe_fun: fn _bytes, _mime_type -> {:ok, "transcribed png text"} end)

      png_bytes = <<0x89, "PNG\r\n", 0x1A, "\n", "not a real png body">>

      assert PdfText.extract(png_bytes) == {:ok, "transcribed png text"}
    end

    test "a PDF whose pdftotext output is empty falls back to vision transcription" do
      test_pid = self()

      stub(
        pdf_to_text_fun: fn _bytes -> {:ok, ""} end,
        pdf_to_images_fun: fn bytes ->
          send(test_pid, {:rasterized, bytes})
          {:ok, ["page 1 bytes", "page 2 bytes"]}
        end,
        vision_transcribe_fun: fn image_bytes, "image/png" ->
          {:ok, "transcribed: #{image_bytes}"}
        end
      )

      pdf_bytes = "%PDF-1.4\nscanned, no text layer"

      assert PdfText.extract(pdf_bytes) ==
               {:ok, "transcribed: page 1 bytes\n\f\ntranscribed: page 2 bytes"}

      assert_received {:rasterized, ^pdf_bytes}
    end

    test "a PDF whose pdftotext output is only whitespace/form-feeds also falls back" do
      stub(
        pdf_to_text_fun: fn _bytes -> {:ok, "\f\n  \f\n"} end,
        pdf_to_images_fun: fn _bytes -> {:ok, ["page"]} end,
        vision_transcribe_fun: fn _bytes, _mime_type -> {:ok, "transcribed"} end
      )

      assert PdfText.extract("%PDF-1.4\nblank-looking") == {:ok, "transcribed"}
    end

    test "a PDF with a real text layer never touches the vision seams" do
      stub(
        pdf_to_text_fun: fn _bytes -> {:ok, "Form W-9. Name of entity: Acme Corp."} end,
        pdf_to_images_fun: fn _bytes -> flunk("should not rasterize a PDF with real text") end,
        vision_transcribe_fun: fn _bytes, _mime_type ->
          flunk("should not call vision on a PDF with real text")
        end
      )

      assert PdfText.extract("%PDF-1.4\nreal text layer") ==
               {:ok, "Form W-9. Name of entity: Acme Corp."}
    end

    test "propagates a pdf_to_images error instead of swallowing it" do
      stub(
        pdf_to_text_fun: fn _bytes -> {:ok, ""} end,
        pdf_to_images_fun: fn _bytes -> {:error, :pdftoppm_not_installed} end
      )

      assert PdfText.extract("%PDF-1.4\nscanned") == {:error, :pdftoppm_not_installed}
    end

    test "propagates a vision_transcribe error instead of swallowing it" do
      stub(vision_transcribe_fun: fn _bytes, _mime_type -> {:error, :vision_call_failed} end)

      jpeg_bytes = <<0xFF, 0xD8, 0xFF, "not a real jpeg body">>

      assert PdfText.extract(jpeg_bytes) == {:error, :vision_call_failed}
    end

    test "stops transcribing further pages once one page errors" do
      test_pid = self()

      stub(
        pdf_to_text_fun: fn _bytes -> {:ok, ""} end,
        pdf_to_images_fun: fn _bytes -> {:ok, ["page 1", "page 2"]} end,
        vision_transcribe_fun: fn
          "page 1", _mime_type ->
            send(test_pid, :page_1_transcribed)
            {:error, :vision_call_failed}

          "page 2", _mime_type ->
            send(test_pid, :page_2_transcribed)
            {:ok, "should never be reached"}
        end
      )

      assert PdfText.extract("%PDF-1.4\nscanned") == {:error, :vision_call_failed}
      assert_received :page_1_transcribed
      refute_received :page_2_transcribed
    end
  end
end
