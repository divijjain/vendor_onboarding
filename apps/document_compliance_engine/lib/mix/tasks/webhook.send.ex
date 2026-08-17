defmodule Mix.Tasks.Webhook.Send do
  @shortdoc "Signs and POSTs an eval fixture to the local webhook endpoint"

  @moduledoc """
  Sends one of the eval harness's fixtures (see `Evals.Fixtures`) to the
  webhook endpoint of an already-running `mix phx.server`, signed the same
  way `VerifyWebhookSignature` expects a real vendor-email-provider request
  to be signed. For manually poking the dashboard with a known-good (or
  known-bad) document pair — the eval harness itself never goes over HTTP.

      mix phx.server            # in one terminal
      mix webhook.send clean-01 # in another

      mix webhook.send mismatch-03 --url http://localhost:4000

  Only fixtures for `vendor_contract_w9` (the `contract`/`w9` pair) are
  supported — `Evals.Fixtures` doesn't have `invoice` fixtures to send.
  """

  use Mix.Task

  alias DocumentComplianceEngine.Agent.Evals.Fixtures

  @requirements ["app.start"]
  @default_url "http://localhost:4000"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: [url: :string])
    fixture = fetch_fixture!(positional)

    body =
      Jason.encode!(%{
        "document_type_slug" => "vendor_contract_w9",
        "documents" => %{
          "contract" => Base.encode64(fixture.contract_text),
          "w9" => Base.encode64(fixture.w9_text)
        }
      })

    url = (opts[:url] || @default_url) <> "/webhooks/document_compliance_engine"

    case Req.post(url,
           body: body,
           headers: [
             {"content-type", "application/json"},
             {"x-webhook-signature", sign(body)}
           ]
         ) do
      {:ok, %Req.Response{status: status, body: resp_body}} ->
        IO.puts("#{status} #{inspect(resp_body)}")

      {:error, reason} ->
        Mix.raise(
          "request failed: #{inspect(reason)} -- is `mix phx.server` running on that URL?"
        )
    end
  end

  defp fetch_fixture!(positional) do
    id =
      case positional do
        [id] -> id
        _ -> Mix.raise("usage: mix webhook.send <fixture_id> [--url http://host:port]")
      end

    case Enum.find(Fixtures.all(), &(&1.id == id)) do
      nil ->
        known = Fixtures.all() |> Enum.map(& &1.id) |> Enum.join(", ")
        Mix.raise("unknown fixture #{inspect(id)}. Known ids: #{known}")

      fixture ->
        fixture
    end
  end

  defp sign(body) do
    secret = Application.fetch_env!(:document_compliance_engine, :webhook_secret)
    hex = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
    "sha256=" <> hex
  end
end
