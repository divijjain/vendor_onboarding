defmodule DocumentComplianceEngineWeb.DocumentControllerTest do
  use DocumentComplianceEngineWeb.ConnCase, async: true

  import DocumentComplianceEngine.AccountsFixtures

  alias DocumentComplianceEngine.DocumentJobs
  alias DocumentComplianceEngine.Storage

  @pdf_bytes "%PDF-1.4\nnot a real PDF body, just needs the magic header"
  @png_bytes <<0x89, "PNG\r\n", 0x1A, "\n", "not a real png body">>

  setup %{conn: conn} do
    owner = user_fixture()
    %{conn: log_in_user(conn, owner), owner: owner}
  end

  defp document_job_with(owner, documents) do
    key = "document-controller-#{System.unique_integer([:positive])}"

    document_paths =
      Map.new(documents, fn {role, bytes} ->
        {:ok, path} = Storage.store("#{key}/#{role}.pdf", bytes)
        {role, path}
      end)

    on_exit(fn ->
      document_paths |> Map.values() |> List.first() |> Path.dirname() |> File.rm_rf()
    end)

    {:ok, document_job} =
      DocumentJobs.Repository.insert(%{
        idempotency_key: key,
        document_paths: document_paths,
        document_type_slug: "vendor_contract_w9",
        owner_user_id: owner.id,
        organization_id: owner.organization_id
      })

    document_job
  end

  describe "content type, sniffed from the bytes rather than the stored extension" do
    test "serves a PDF inline as application/pdf", %{conn: conn, owner: owner} do
      document_job = document_job_with(owner, %{"contract" => @pdf_bytes})

      conn = get(conn, ~p"/document_jobs/#{document_job.id}/documents/contract")

      assert response(conn, 200) == @pdf_bytes
      assert get_resp_header(conn, "content-type") == ["application/pdf"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="contract.pdf")]
    end

    test "serves a PNG inline as image/png even though it was stored as .pdf", %{
      conn: conn,
      owner: owner
    } do
      document_job = document_job_with(owner, %{"w9" => @png_bytes})

      conn = get(conn, ~p"/document_jobs/#{document_job.id}/documents/w9")

      assert response(conn, 200) == @png_bytes
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "content-disposition") == [~s(inline; filename="w9.png")]
    end

    test "serves unrecognized bytes as a plain-text attachment, never inline", %{
      conn: conn,
      owner: owner
    } do
      document_job = document_job_with(owner, %{"contract" => "<html>not a document</html>"})

      conn = get(conn, ~p"/document_jobs/#{document_job.id}/documents/contract")

      assert response(conn, 200) == "<html>not a document</html>"
      assert get_resp_header(conn, "content-type") == ["text/plain"]

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="contract.bin")]
    end

    test "sanitizes a role before putting it in the filename header", %{conn: conn, owner: owner} do
      # Roles are `documents` map keys straight from the webhook payload,
      # so a quote here would otherwise break out of the filename.
      role = ~s(we"ird role)
      document_job = document_job_with(owner, %{role => @pdf_bytes})

      conn = get(conn, ~p"/document_jobs/#{document_job.id}/documents/#{role}")

      assert response(conn, 200) == @pdf_bytes

      assert get_resp_header(conn, "content-disposition") ==
               [~s(inline; filename="we_ird_role.pdf")]
    end
  end

  describe "authorization" do
    test "a user in another organization gets the same 404 as a missing job", %{owner: owner} do
      document_job = document_job_with(owner, %{"contract" => @pdf_bytes})
      other_user = user_fixture()

      conn =
        build_conn()
        |> log_in_user(other_user)
        |> get(~p"/document_jobs/#{document_job.id}/documents/contract")

      assert response(conn, 404)
    end

    test "an unauthenticated request is redirected to the login page", %{owner: owner} do
      document_job = document_job_with(owner, %{"contract" => @pdf_bytes})

      conn = get(build_conn(), ~p"/document_jobs/#{document_job.id}/documents/contract")

      assert redirected_to(conn) == ~p"/"
    end

    test "a role that isn't on the document_job is a 404", %{conn: conn, owner: owner} do
      document_job = document_job_with(owner, %{"contract" => @pdf_bytes})

      conn = get(conn, ~p"/document_jobs/#{document_job.id}/documents/w9")

      assert response(conn, 404)
    end

    test "a nonexistent document_job id is a 404", %{conn: conn} do
      conn = get(conn, ~p"/document_jobs/#{0}/documents/contract")

      assert response(conn, 404)
    end
  end
end
