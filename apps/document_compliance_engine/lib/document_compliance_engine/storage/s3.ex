defmodule DocumentComplianceEngine.Storage.S3 do
  @moduledoc """
  S3-compatible object storage adapter — the production `Storage` adapter
  (`LocalDisk` stays the dev/test default). Talks to any S3 API
  implementation via a configurable `endpoint` (Fly's Tigris today; real
  AWS S3 later would need no code change, just different config). Built on
  `Req` + `aws_signature` rather than `ex_aws`/`hackney` — matches
  `CLAUDE.md`'s "use Req for HTTP" rule and the same small-hand-rolled-
  client-over-a-heavy-library call already made for `agent/mcp_client.ex`.
  """

  @behaviour DocumentComplianceEngine.Storage

  @impl true
  def store(key, content) do
    case request(:put, key, content) do
      {:ok, %{status: status}} when status in 200..299 -> {:ok, key}
      {:ok, %{status: status, body: body}} -> {:error, {:s3_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def read(key) do
    case request(:get, key, "") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:s3_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(method, key, body) do
    config = Application.fetch_env!(:document_compliance_engine, :s3)
    bucket = Keyword.fetch!(config, :bucket)
    region = Keyword.fetch!(config, :region)
    endpoint = config |> Keyword.fetch!(:endpoint) |> String.trim_trailing("/")

    url = "#{endpoint}/#{bucket}/#{key}"
    host = url |> URI.parse() |> Map.fetch!(:host)

    headers =
      :aws_signature.sign_v4(
        Keyword.fetch!(config, :access_key_id),
        Keyword.fetch!(config, :secret_access_key),
        region,
        "s3",
        :calendar.universal_time(),
        method |> Atom.to_string() |> String.upcase(),
        url,
        [{"host", host}],
        body
      )

    # Sign with the literal body — AWS requires the empty-string digest for
    # a bodyless GET — but hand Req `nil`, not `""`, for the actual request:
    # Req's `get_to_post` step silently rewrites `method: :get` to `:post`
    # whenever `body != nil`, and `"" != nil`. Signing as GET while the
    # wire method flips to POST would send a request whose SigV4 signature
    # doesn't match what was actually sent — S3/Tigris would reject every
    # read with SignatureDoesNotMatch. Caught by `s3_test.exs`, not assumed.
    req_body = if body == "", do: nil, else: body

    [method: method, url: url, headers: headers, body: req_body, retry: false]
    |> maybe_add_test_plug()
    |> Req.request()
  end

  # Overridable the same way the agent's external calls are (see
  # `agent/mcp_client.ex`/`CLAUDE.md`) — lets tests stub the HTTP layer via
  # `Req.Test` instead of hitting real S3/Tigris. Unset in dev/prod, where
  # the real request goes out normally.
  defp maybe_add_test_plug(opts) do
    case Application.get_env(:document_compliance_engine, :s3_req_plug) do
      nil -> opts
      plug -> Keyword.put(opts, :plug, plug)
    end
  end
end
