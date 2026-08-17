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
end
