import json

from mcp_servers.sanctions_db.main import mcp_server


async def _call(company_name: str) -> dict:
    result = await mcp_server.call_tool("screen_vendor", {"company_name": company_name})
    return json.loads(result.content[0].text)


async def test_screen_vendor_clears_an_unlisted_company():
    assert await _call("Acme Corp") == {"flagged": False, "reason": None}


async def test_screen_vendor_flags_a_listed_company_case_insensitively():
    result = await _call("Rogue Exports LLC")
    assert result["flagged"] is True
    assert result["reason"] is not None
