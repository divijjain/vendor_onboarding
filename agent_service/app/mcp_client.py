"""Client wrapper for the two MCP tool servers. Each function is a thin,
independently-injectable async call — Agent 2 (app/graph.py) takes them as
parameters so tests never need the real MCP server processes running.
"""

import json
import os

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from app.schemas import SanctionsScreeningResult, TaxValidationResult


def tax_api_url() -> str:
    return os.environ.get("TAX_API_MCP_URL", "http://localhost:8010/mcp")


def sanctions_db_url() -> str:
    return os.environ.get("SANCTIONS_DB_MCP_URL", "http://localhost:8011/mcp")


async def _call_tool(url: str, tool_name: str, arguments: dict) -> dict:
    async with streamable_http_client(url) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            result = await session.call_tool(tool_name, arguments)
            return json.loads(result.content[0].text)


async def validate_tax_id(tax_id: str) -> TaxValidationResult:
    raw = await _call_tool(tax_api_url(), "validate_tax_id", {"tax_id": tax_id})
    return TaxValidationResult(**raw)


async def screen_vendor(company_name: str) -> SanctionsScreeningResult:
    raw = await _call_tool(sanctions_db_url(), "screen_vendor", {"company_name": company_name})
    return SanctionsScreeningResult(**raw)
