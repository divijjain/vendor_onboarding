defmodule VendorOnboarding.Agent.McpClient do
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
  """

  @protocol_version "2025-06-18"
  @accept "application/json, text/event-stream"

  @spec validate_tax_id(String.t()) :: {:ok, %{valid: boolean()}} | {:error, term()}
  def validate_tax_id(tax_id) do
    case Application.get_env(:vendor_onboarding, :agent_validate_tax_id) do
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
    case Application.get_env(:vendor_onboarding, :agent_screen_vendor) do
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
    with {:ok, session_id} <- initialize(url),
         :ok <- notify_initialized(url, session_id),
         {:ok, result} <-
           request(url, session_id, "tools/call", %{name: tool_name, arguments: arguments}) do
      decode_tool_result(result)
    end
  end

  defp initialize(url) do
    body =
      rpc("initialize", %{
        protocolVersion: @protocol_version,
        capabilities: %{},
        clientInfo: %{name: "agent-service", version: "0.1.0"}
      })

    case Req.post(url, json: body, headers: [accept: @accept], receive_timeout: 10_000) do
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

  defp notify_initialized(url, session_id) do
    body = %{jsonrpc: "2.0", method: "notifications/initialized"}

    case Req.post(url, json: body, headers: headers(session_id), receive_timeout: 10_000) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:mcp_notify_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(url, session_id, method, params) do
    body = rpc(method, params)

    case Req.post(url, json: body, headers: headers(session_id), receive_timeout: 30_000) do
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

  defp headers(session_id), do: [accept: @accept, "mcp-session-id": session_id]

  defp tax_api_url do
    System.get_env("TAX_API_MCP_URL") || "http://localhost:8010/mcp"
  end

  defp sanctions_db_url do
    System.get_env("SANCTIONS_DB_MCP_URL") || "http://localhost:8011/mcp"
  end
end
