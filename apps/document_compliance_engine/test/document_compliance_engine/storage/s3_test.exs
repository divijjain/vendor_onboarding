defmodule DocumentComplianceEngine.Storage.S3Test do
  use ExUnit.Case, async: true

  alias DocumentComplianceEngine.Storage.S3

  setup do
    Application.put_env(:document_compliance_engine, :s3_req_plug, {Req.Test, S3Test})
    on_exit(fn -> Application.delete_env(:document_compliance_engine, :s3_req_plug) end)
  end

  test "store/2 PUTs the content to the configured bucket/key and returns the key on success" do
    key = "abc123/w9.pdf"

    Req.Test.stub(S3Test, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/test-bucket/#{key}"
      assert get_req_header(conn, "authorization") != []

      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert S3.store(key, "pdf-bytes") == {:ok, key}
  end

  test "store/2 returns an error tuple on a non-2xx response" do
    key = "abc123/w9.pdf"

    Req.Test.stub(S3Test, fn conn ->
      Plug.Conn.send_resp(conn, 403, "AccessDenied")
    end)

    assert S3.store(key, "pdf-bytes") == {:error, {:s3_error, 403, "AccessDenied"}}
  end

  test "read/1 GETs the object and returns its body on success" do
    key = "abc123/w9.pdf"

    Req.Test.stub(S3Test, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/test-bucket/#{key}"

      Plug.Conn.send_resp(conn, 200, "pdf-bytes")
    end)

    assert S3.read(key) == {:ok, "pdf-bytes"}
  end

  test "read/1 returns :not_found on a 404" do
    Req.Test.stub(S3Test, fn conn ->
      Plug.Conn.send_resp(conn, 404, "NoSuchKey")
    end)

    assert S3.read("missing/w9.pdf") == {:error, :not_found}
  end

  defp get_req_header(conn, key), do: Plug.Conn.get_req_header(conn, key)
end
