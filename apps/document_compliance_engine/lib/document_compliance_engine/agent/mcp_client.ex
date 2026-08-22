defmodule DocumentComplianceEngine.Agent.McpClient do
  @moduledoc """
  Client for the two MCP tool servers, speaking MCP's streamable-HTTP
  transport (JSON-RPC 2.0 over POST) directly on `Req`.

  Deliberately not `hermes_mcp`'s client: that library is used for the
  servers, but its client passes `transport_opts` as a per-request Finch
  option, which Finch >= 0.21 rejects — and the only Req old enough to
  hold Finch back has published CVEs. The server side has no such
  constraint, so the tool servers remain real `hermes_mcp` servers.

  A session is established per call, matching how the previous client
  behaved; these are mock tools and the handshake is two cheap local
  round-trips.

  On Fly, `TAX_API_MCP_URL`/`SANCTIONS_DB_MCP_URL` point at `.internal`
  hostnames that only have AAAA records — Fly's private network (6PN) is
  IPv6-only. `:inet.gethostbyname/1` (Erlang's default, IPv4-only lookup)
  returns `nxdomain` for these; `:inet.gethostbyname/2` with `:inet6`
  resolves them fine — proven directly against a deployed instance, not
  just inferred. Req's own `inet6: true` option (the equivalent of
  Postgrex's `ECTO_IPV6`) turned out *not* to be enough on its own: it
  sets the connect socket's family once an IP is known, but Finch/Mint's
  own hostname-resolution step still runs Erlang's default (IPv4-only)
  lookup and fails before that ever applies. So this resolves the host to
  an IPv6 literal itself and substitutes it directly into the request URL
  — sidesteps the ambiguity entirely instead of fighting Finch's internals.

  Req.Finch *does* notice a literal IPv6 host (it checks for a `:` in
  `URI.parse/1`'s stripped-of-brackets `.host`) and auto-adds a bracketed
  `Host` header — but its version omits the port, which Bandit rejects
  outright (`Header contains invalid port`, confirmed against a deployed
  instance). So the `Host` header is set explicitly here too, rather than
  relying on that auto-injection.

  Only runs when `FLY_APP_NAME` is set (present on every Fly machine
  automatically), so this never fires against `localhost` in dev/test.
  """

  @protocol_version "2025-06-18"
  @accept "application/json, text/event-stream"

  @spec validate_tax_id(String.t()) :: {:ok, %{valid: boolean()}} | {:error, term()}
  def validate_tax_id(tax_id) do
    case Application.get_env(:document_compliance_engine, :agent_validate_tax_id) do
      nil ->
        with {:ok, %{"valid" => valid}} <-
               call_tool(tax_api_url(), "validate_tax_id", %{tax_id: tax_id}) do
          {:ok, %{valid: valid}}
        end

      fun ->
        fun.(tax_id)
    end
  end

  @spec screen_vendor(String.t()) ::
          {:ok, %{flagged: boolean(), reason: String.t() | nil}} | {:error, term()}
  def screen_vendor(company_name) do
    case Application.get_env(:document_compliance_engine, :agent_screen_vendor) do
      nil ->
        with {:ok, %{"flagged" => flagged} = payload} <-
               call_tool(sanctions_db_url(), "screen_vendor", %{company_name: company_name}) do
          {:ok, %{flagged: flagged, reason: payload["reason"]}}
        end

      fun ->
        fun.(company_name)
    end
  end

  defp call_tool(url, tool_name, arguments) do
    {url, host_header} = maybe_resolve_ipv6(url)

    with {:ok, session_id} <- initialize(url, host_header),
         :ok <- notify_initialized(url, session_id, host_header),
         {:ok, result} <-
           request(url, session_id, host_header, "tools/call", %{
             name: tool_name,
             arguments: arguments
           }) do
      decode_tool_result(result)
    end
  end

  # See moduledoc — Erlang's default (IPv4-only) hostname resolution
  # returns nxdomain for Fly's `.internal` hosts, and Req/Finch's own
  # `inet6: true` option doesn't reach far enough into Mint's connection
  # setup to fix that. Resolving to a literal here and substituting it
  # into the URL sidesteps the problem instead of fighting it. Returns the
  # explicit `Host` header to send alongside it (Req.Finch's own
  # auto-injected one omits the port — see moduledoc), or `nil` when no
  # substitution happened.
  defp maybe_resolve_ipv6(url) do
    if System.get_env("FLY_APP_NAME") do
      uri = URI.parse(url)

      case :inet.gethostbyname(String.to_charlist(uri.host), :inet6) do
        {:ok, {:hostent, _, _, :inet6, _, [ip | _]}} ->
          host_header = "[#{:inet.ntoa(ip)}]:#{uri.port}"
          {"#{uri.scheme}://#{host_header}#{uri.path}", host_header}

        _ ->
          {url, nil}
      end
    else
      {url, nil}
    end
  end

  defp initialize(url, host_header) do
    body =
      rpc("initialize", %{
        protocolVersion: @protocol_version,
        capabilities: %{},
        clientInfo: %{name: "agent-service", version: "0.1.0"}
      })

    opts =
      [
        json: body,
        headers: [accept: @accept] ++ host_header(host_header),
        receive_timeout: 10_000
      ] ++
        req_opts()

    case Req.post(url, opts) do
      {:ok, %Req.Response{status: 200} = response} ->
        session_id(response)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:mcp_initialize_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp session_id(response) do
    case Req.Response.get_header(response, "mcp-session-id") do
      [session_id | _] -> {:ok, session_id}
      [] -> {:error, :missing_mcp_session_id}
    end
  end

  defp notify_initialized(url, session_id, host_header) do
    body = %{jsonrpc: "2.0", method: "notifications/initialized"}

    opts =
      [json: body, headers: headers(session_id, host_header), receive_timeout: 10_000] ++
        req_opts()

    case Req.post(url, opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:mcp_notify_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(url, session_id, host_header, method, params) do
    body = rpc(method, params)

    opts =
      [json: body, headers: headers(session_id, host_header), receive_timeout: 30_000] ++
        req_opts()

    case Req.post(url, opts) do
      {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
        {:error, {:mcp_error, error}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:mcp_request_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Tool results arrive as a content list; the mock servers return a single
  # JSON text block.
  defp decode_tool_result(%{"content" => [%{"text" => text} | _]}), do: Jason.decode(text)
  defp decode_tool_result(other), do: {:error, {:unexpected_tool_result, other}}

  defp rpc(method, params) do
    %{jsonrpc: "2.0", id: unique_id(), method: method, params: params}
  end

  defp unique_id, do: "req_#{System.unique_integer([:positive, :monotonic])}"

  defp headers(session_id, host_header),
    do: [accept: @accept, "mcp-session-id": session_id] ++ host_header(host_header)

  defp host_header(nil), do: []
  defp host_header(value), do: [host: value]

  defp req_opts do
    if System.get_env("FLY_APP_NAME"), do: [inet6: true], else: []
  end

  defp tax_api_url do
    System.get_env("TAX_API_MCP_URL") || "http://localhost:8010/mcp"
  end

  defp sanctions_db_url do
    System.get_env("SANCTIONS_DB_MCP_URL") || "http://localhost:8011/mcp"
  end
end
