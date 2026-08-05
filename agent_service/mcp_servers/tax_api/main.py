"""Mock Tax API — a real, separate FastAPI process exposing one MCP tool.
Validates Tax ID / EIN format against a mock government registry. Not a
function folded into the agent process; see CONTEXT.md's MCP rationale.
"""

import re

from mcp.server.mcpserver import MCPServer

from mcp_servers.asgi import build_app

EIN_PATTERN = re.compile(r"^\d{2}-\d{7}$")

mcp_server = MCPServer(name="tax-api")


@mcp_server.tool()
def validate_tax_id(tax_id: str) -> dict:
    """Look up a Tax ID / EIN in the mock government tax registry."""
    return {"valid": bool(EIN_PATTERN.match(tax_id.strip()))}


app = build_app(mcp_server)
