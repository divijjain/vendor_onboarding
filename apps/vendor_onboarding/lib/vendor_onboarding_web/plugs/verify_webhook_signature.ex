defmodule VendorOnboardingWeb.Plugs.VerifyWebhookSignature do
  @moduledoc """
  Rejects webhook requests that aren't signed by the vendor-email provider.

  Idempotency and PII-at-rest were already covered, but the ingestion
  endpoint itself accepted any POST — anyone who found the URL could inject
  fabricated vendor data. Verifies an HMAC-SHA256 signature (hex-encoded,
  `sha256=<hex>`) over the exact raw body bytes captured by
  `CacheBodyReader`, using the same bytes the idempotency key is hashed
  from. Comparison is constant-time via `Plug.Crypto.secure_compare/2`.
  """

  import Plug.Conn

  @header "x-webhook-signature"

  def init(opts), do: opts

  def call(conn, _opts) do
    secret = Application.fetch_env!(:vendor_onboarding, :webhook_secret)

    with [signature] <- get_req_header(conn, @header),
         "sha256=" <> hex <- signature,
         expected <- expected_signature(secret, conn.assigns.raw_body),
         true <- Plug.Crypto.secure_compare(hex, expected) do
      conn
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "invalid_signature"})
        |> halt()
    end
  end

  defp expected_signature(secret, raw_body) do
    :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)
  end
end
