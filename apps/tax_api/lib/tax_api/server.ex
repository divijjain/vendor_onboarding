defmodule TaxApi.Server do
  @moduledoc """
  Mock Tax API — a real, separate process exposing one MCP tool. Validates
  Tax ID / EIN format against a mock government registry. Not a function
  folded into the agent process; see CONTEXT.md's MCP rationale.
  """

  use Hermes.Server,
    name: "tax-api",
    version: "1.0.0",
    capabilities: [:tools]

  alias Hermes.Server.Response

  @ein_pattern ~r/^\d{2}-\d{7}$/

  @impl true
  def init(_client_info, frame) do
    {:ok,
     register_tool(frame, "validate_tax_id",
       input_schema: %{
         tax_id: {:required, :string, description: "Tax ID / EIN to look up"}
       },
       annotations: %{read_only: true},
       description: "Look up a Tax ID / EIN in the mock government tax registry."
     )}
  end

  @impl true
  def handle_tool_call("validate_tax_id", %{tax_id: tax_id}, frame) do
    {:reply, Response.json(Response.tool(), valid?(tax_id)), frame}
  end

  @doc "The registry rule itself — pure, so it can be tested without the server."
  @spec valid?(String.t()) :: %{valid: boolean()}
  def valid?(tax_id) do
    %{valid: Regex.match?(@ein_pattern, String.trim(tax_id))}
  end
end
