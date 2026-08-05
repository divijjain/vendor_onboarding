"""Mock Sanctions DB — a real, separate FastAPI process exposing one MCP
tool. Screens a vendor name against a mock sanctions watchlist.
"""

from mcp.server.mcpserver import MCPServer

from mcp_servers.asgi import build_app

# Deliberately small and deterministic — this is a mock external system,
# not a real sanctions feed.
_SANCTIONED_NAMES = {"rogue exports llc", "north star trading co"}

mcp_server = MCPServer(name="sanctions-db")


@mcp_server.tool()
def screen_vendor(company_name: str) -> dict:
    """Screen a vendor's company name against the mock sanctions watchlist."""
    normalized = company_name.strip().lower()
    flagged = normalized in _SANCTIONED_NAMES
    return {
        "flagged": flagged,
        "reason": "Matched sanctions watchlist entry" if flagged else None,
    }


app = build_app(mcp_server)
