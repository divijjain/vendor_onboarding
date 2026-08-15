defmodule SanctionsDb.Server do
  @moduledoc """
  Mock Sanctions DB — a real, separate process exposing one MCP tool.
  Screens a vendor name against a mock sanctions watchlist.
  """

  use Hermes.Server,
    name: "sanctions-db",
    version: "1.0.0",
    capabilities: [:tools]

  alias Hermes.Server.Response

  # Deliberately small and deterministic — this is a mock external system,
  # not a real sanctions feed.
  @sanctioned_names MapSet.new(["rogue exports llc", "north star trading co"])

  @impl true
  def init(_client_info, frame) do
    {:ok,
     register_tool(frame, "screen_vendor",
       input_schema: %{
         company_name: {:required, :string, description: "Vendor company name to screen"}
       },
       annotations: %{read_only: true},
       description: "Screen a vendor's company name against the mock sanctions watchlist."
     )}
  end

  @impl true
  def handle_tool_call("screen_vendor", %{company_name: company_name}, frame) do
    {:reply, Response.json(Response.tool(), screen(company_name)), frame}
  end

  @doc "The watchlist rule itself — pure, so it can be tested without the server."
  @spec screen(String.t()) :: %{flagged: boolean(), reason: String.t() | nil}
  def screen(company_name) do
    flagged =
      MapSet.member?(@sanctioned_names, company_name |> String.trim() |> String.downcase())

    %{flagged: flagged, reason: if(flagged, do: "Matched sanctions watchlist entry")}
  end
end
