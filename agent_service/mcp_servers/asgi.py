"""Shared FastAPI+MCP mounting for both mock tool servers.

`MCPServer.streamable_http_app()` returns a Starlette app with its own
lifespan (it starts/stops the streamable-HTTP session manager). Starlette
doesn't propagate a mounted sub-app's lifespan automatically, so the parent
FastAPI app's lifespan has to explicitly enter it — otherwise every request
fails with "Task group is not initialized."
"""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from mcp.server.mcpserver import MCPServer


def build_app(mcp_server: MCPServer) -> FastAPI:
    mcp_app = mcp_server.streamable_http_app(streamable_http_path="/")

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        async with mcp_app.router.lifespan_context(mcp_app):
            yield

    app = FastAPI(title=mcp_server.name, lifespan=lifespan)
    app.mount("/mcp", mcp_app)
    return app
