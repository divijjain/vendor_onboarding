defmodule DocumentComplianceEngine.Agent.ChecksTest do
  use ExUnit.Case, async: false

  import DocumentComplianceEngine.AgentFakes

  alias DocumentComplianceEngine.Agent.{Checks, ValidationResult}
  alias DocumentComplianceEngine.Agent.Schemas.EntityMatchResult

  @extracted %{
    "contract" => %{company_name: "Acme Corp"},
    "w9" => %{company_name: "Acme Corp", tax_id: "12-3456789"}
  }

  @entity_match_rule %{
    "type" => "entity_match",
    "fields" => [
      %{"role" => "contract", "name" => "company_name"},
      %{"role" => "w9", "name" => "company_name"}
    ]
  }

  @tax_id_rule %{
    "type" => "mcp_tool",
    "tool" => "validate_tax_id",
    "field" => %{"role" => "w9", "name" => "tax_id"}
  }

  @sanctions_rule %{
    "type" => "mcp_tool",
    "tool" => "screen_vendor",
    "field" => %{"role" => "contract", "name" => "company_name"}
  }

  test "entity_match rule passes when the two named fields match" do
    stub_defaults()

    assert {:ok, %ValidationResult{checks: [check]}} =
             Checks.validate_all(@extracted, [@entity_match_rule])

    assert check.passed
    assert check.detail == nil
  end

  test "entity_match rule fails and records a detail on mismatch" do
    stub_defaults(
      entity_match: fn _a, _b ->
        {:ok, %EntityMatchResult{match: false, explanation: "different entities"}}
      end
    )

    assert {:ok, result} = Checks.validate_all(@extracted, [@entity_match_rule])
    refute ValidationResult.approved?(result)
    assert [check] = result.checks
    assert check.detail =~ "Entity name mismatch: different entities"
  end

  test "mcp_tool validate_tax_id rule fails on an invalid tax id" do
    stub_defaults(validate_tax_id: fn _tax_id -> {:ok, %{valid: false}} end)

    assert {:ok, result} = Checks.validate_all(@extracted, [@tax_id_rule])
    refute ValidationResult.approved?(result)
    assert [check] = result.checks
    assert check.detail =~ "Tax ID failed validation"
  end

  test "mcp_tool screen_vendor rule fails on a sanctions hit" do
    stub_defaults(screen_vendor: fn _name -> {:ok, %{flagged: true, reason: "on watchlist"}} end)

    assert {:ok, result} = Checks.validate_all(@extracted, [@sanctions_rule])
    refute ValidationResult.approved?(result)
    assert [check] = result.checks
    assert check.detail =~ "Sanctions screening hit: on watchlist"
  end

  test "approved? is true only when every rule passes" do
    stub_defaults()

    assert {:ok, result} = Checks.validate_all(@extracted, [@tax_id_rule, @sanctions_rule])
    assert ValidationResult.approved?(result)
  end

  test "describe_findings joins only the failed checks' details" do
    stub_defaults(
      validate_tax_id: fn _tax_id -> {:ok, %{valid: false}} end,
      screen_vendor: fn _name -> {:ok, %{flagged: true, reason: "on watchlist"}} end
    )

    assert {:ok, result} = Checks.validate_all(@extracted, [@tax_id_rule, @sanctions_rule])
    findings = Checks.describe_findings(result)

    assert findings =~ "Tax ID failed validation"
    assert findings =~ "Sanctions screening hit: on watchlist"
  end
end
