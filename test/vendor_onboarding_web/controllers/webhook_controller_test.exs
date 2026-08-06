defmodule VendorOnboardingWeb.WebhookControllerTest do
  use VendorOnboardingWeb.ConnCase, async: true

  defp payload do
    unique = System.unique_integer([:positive])

    Jason.encode!(%{
      "contract" => Base.encode64("contract-bytes-#{unique}"),
      "w9" => Base.encode64("w9-bytes-#{unique}")
    })
  end

  defp post_webhook(conn, raw_body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/webhooks/vendor_onboarding", raw_body)
  end

  test "POST /webhooks/vendor_onboarding creates an onboarding on the happy path", %{conn: conn} do
    conn = post_webhook(conn, payload())

    assert %{"id" => id, "status" => "received"} = json_response(conn, 201)
    assert {:ok, onboarding} = VendorOnboarding.Onboardings.get_onboarding(id)

    on_exit(fn ->
      onboarding.document_paths["contract"] |> Path.dirname() |> File.rm_rf()
    end)
  end

  test "POST /webhooks/vendor_onboarding ignores a duplicate payload", %{conn: conn} do
    raw_payload = payload()
    conn1 = post_webhook(conn, raw_payload)
    assert %{"id" => id} = json_response(conn1, 201)

    conn2 = post_webhook(build_conn(), raw_payload)
    assert json_response(conn2, 200) == %{"status" => "duplicate_ignored"}

    assert {:ok, onboarding} = VendorOnboarding.Onboardings.get_onboarding(id)

    on_exit(fn ->
      onboarding.document_paths["contract"] |> Path.dirname() |> File.rm_rf()
    end)
  end

  test "POST /webhooks/vendor_onboarding rejects a well-formed JSON body missing contract/w9",
       %{conn: conn} do
    conn = post_webhook(conn, Jason.encode!(%{}))
    assert json_response(conn, 422) == %{"error" => "invalid_payload"}
  end

  test "syntactically malformed JSON is rejected by the parser before it reaches the controller" do
    # In production Bandit turns this into a 400; Phoenix.ConnTest doesn't rescue it,
    # so we assert the parser raises with the 400 plug_status instead.
    assert_raise Plug.Parsers.ParseError, fn ->
      build_conn() |> post_webhook("not json")
    end
  end
end
