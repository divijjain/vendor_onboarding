defmodule DocumentComplianceEngine.SystemHealth do
  @moduledoc """
  Read-only operational snapshot for the dashboard's health panel: BEAM
  process count, Oban queue depth, active agent run count, and MCP server
  reachability. Deliberately not a context with its own table — it reads
  Oban's own job table directly (infra, owned by neither `DocumentJobs`
  nor `AgentRuns`) and calls `AgentRuns`' public API for the one domain
  figure it needs, never `AgentRuns.Repository` directly.
  """

  import Ecto.Query

  alias DocumentComplianceEngine.AgentRuns
  alias DocumentComplianceEngine.Repo

  @type mcp_status :: :up | :down

  @type t :: %{
          beam_process_count: pos_integer(),
          oban_queue_depth: non_neg_integer(),
          active_agent_runs: non_neg_integer(),
          pending_audits: non_neg_integer(),
          tax_api_status: mcp_status(),
          sanctions_db_status: mcp_status()
        }

  @doc """
  `pending_audits` is scoped to `organization_id` — the audit queue is
  siloed per-organization, so a global count here would mismatch what
  `/audits` actually shows that organization. Every other figure stays
  system-wide (infra facts, not user data).
  """
  @spec snapshot(pos_integer()) :: t()
  def snapshot(organization_id) do
    %{
      beam_process_count: :erlang.system_info(:process_count),
      oban_queue_depth: oban_queue_depth(),
      active_agent_runs: AgentRuns.count_active(),
      pending_audits: AgentRuns.count_pending_audits(organization_id),
      tax_api_status: mcp_status(tax_api_health_url()),
      sanctions_db_status: mcp_status(sanctions_db_health_url())
    }
  end

  defp oban_queue_depth do
    Oban.Job
    |> where(state: "available")
    |> Repo.aggregate(:count)
  end

  # A bare GET to the server's root — deliberately not `/mcp` itself, which
  # would engage the real MCP handshake `Agent.McpClient` uses. Any HTTP
  # response (including the router's 404 fallback) means Bandit is up and
  # accepting connections; a connection error means the process is down.
  defp mcp_status(url) do
    case status_check_fun().(url) do
      {:ok, %Req.Response{}} -> :up
      {:error, _reason} -> :down
    end
  end

  defp status_check_fun do
    Application.get_env(
      :document_compliance_engine,
      :system_health_mcp_check_fun,
      &default_check/1
    )
  end

  defp default_check(url), do: Req.get(url, receive_timeout: 1_000, retry: false)

  defp tax_api_health_url do
    System.get_env("TAX_API_HEALTH_URL") || "http://localhost:8010/"
  end

  defp sanctions_db_health_url do
    System.get_env("SANCTIONS_DB_HEALTH_URL") || "http://localhost:8011/"
  end
end
