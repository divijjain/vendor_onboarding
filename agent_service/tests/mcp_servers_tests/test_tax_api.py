import json

from mcp_servers.tax_api.main import mcp_server


async def _call(tax_id: str) -> dict:
    result = await mcp_server.call_tool("validate_tax_id", {"tax_id": tax_id})
    return json.loads(result.content[0].text)


async def test_validate_tax_id_accepts_a_well_formed_ein():
    assert await _call("12-3456789") == {"valid": True}


async def test_validate_tax_id_rejects_a_malformed_value():
    assert await _call("not-an-ein") == {"valid": False}
    assert await _call("") == {"valid": False}
