defmodule DocumentComplianceEngineWeb.WebhookControllerTest do
  use DocumentComplianceEngineWeb.ConnCase, async: true

  defp payload do
    unique = System.unique_integer([:positive])

    Jason.encode!(%{
      "document_type_slug" => "vendor_contract_w9",
      "documents" => %{
        "contract" => Base.encode64("contract-bytes-#{unique}"),
        "w9" => Base.encode64("w9-bytes-#{unique}")
      },
      "owner_email" => "webhook-#{unique}@example.com"
    })
  end

  defp post_webhook(conn, raw_body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-webhook-signature", sign_webhook_body(raw_body))
    |> post(~p"/webhooks/document_compliance_engine", raw_body)
  end

  test "POST /webhooks/document_compliance_engine creates an document_job on the happy path", %{
    conn: conn
  } do
    conn = post_webhook(conn, payload())

    assert %{"id" => id, "status" => "received"} = json_response(conn, 201)
    assert {:ok, document_job} = DocumentComplianceEngine.DocumentJobs.get_document_job(id)

    on_exit(fn ->
      document_job.document_paths["contract"] |> Path.dirname() |> File.rm_rf()
    end)
  end

  test "POST /webhooks/document_compliance_engine ignores a duplicate payload", %{conn: conn} do
    raw_payload = payload()
    conn1 = post_webhook(conn, raw_payload)
    assert %{"id" => id} = json_response(conn1, 201)

    conn2 = post_webhook(build_conn(), raw_payload)
    assert json_response(conn2, 200) == %{"status" => "duplicate_ignored"}

    assert {:ok, document_job} = DocumentComplianceEngine.DocumentJobs.get_document_job(id)

    on_exit(fn ->
      document_job.document_paths["contract"] |> Path.dirname() |> File.rm_rf()
    end)
  end

  test "POST /webhooks/document_compliance_engine rejects a well-formed JSON body missing document_type_slug/documents",
       %{conn: conn} do
    conn = post_webhook(conn, Jason.encode!(%{}))
    assert json_response(conn, 422) == %{"error" => "invalid_payload"}
  end

  test "POST /webhooks/document_compliance_engine rejects an unknown document_type_slug", %{
    conn: conn
  } do
    raw_payload =
      Jason.encode!(%{
        "document_type_slug" => "not_a_real_type",
        "documents" => %{"invoice" => Base.encode64("x")},
        "owner_email" => "webhook-unknown-type@example.com"
      })

    conn = post_webhook(conn, raw_payload)
    assert json_response(conn, 422) == %{"error" => "unknown_document_type"}
  end

  test "POST /webhooks/document_compliance_engine rejects a request with no signature header", %{
    conn: conn
  } do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/document_compliance_engine", payload())

    assert json_response(conn, 401) == %{"error" => "invalid_signature"}
  end

  test "POST /webhooks/document_compliance_engine rejects a request with a wrong signature", %{
    conn: conn
  } do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-webhook-signature", "sha256=" <> String.duplicate("0", 64))
      |> post(~p"/webhooks/document_compliance_engine", payload())

    assert json_response(conn, 401) == %{"error" => "invalid_signature"}
  end

  test "syntactically malformed JSON is rejected by the parser before it reaches the controller" do
    # In production Bandit turns this into a 400; Phoenix.ConnTest doesn't rescue it,
    # so we assert the parser raises with the 400 plug_status instead.
    assert_raise Plug.Parsers.ParseError, fn ->
      build_conn() |> post_webhook("not json")
    end
  end
end
