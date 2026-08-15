defmodule VendorOnboarding.Agent.ChecksTest do
  use ExUnit.Case, async: false

  import VendorOnboarding.AgentFakes

  alias VendorOnboarding.Agent.Checks
  alias VendorOnboarding.Agent.Schemas.EntityMatchResult
  alias VendorOnboarding.Agent.ValidationResult

  defp validation(overrides) do
    struct(
      %ValidationResult{
        entity_match: %EntityMatchResult{match: true, explanation: "same entity"},
        tax_id_valid: true,
        sanctions_flagged: false
      },
      overrides
    )
  end

  test "approved? requires a match, a valid tax id, and no sanctions hit" do
    assert ValidationResult.approved?(validation(%{}))

    refute ValidationResult.approved?(
             validation(%{
               entity_match: %EntityMatchResult{match: false, explanation: "different vendor"}
             })
           )

    refute ValidationResult.approved?(validation(%{tax_id_valid: false}))
    refute ValidationResult.approved?(validation(%{sanctions_flagged: true}))
  end

  test "describe_findings lists every failed check" do
    findings =
      Checks.describe_findings(
        validation(%{
          entity_match: %EntityMatchResult{match: false, explanation: "names differ"},
          tax_id_valid: false,
          sanctions_flagged: true,
          sanctions_reason: "watchlist"
        })
      )

    assert findings =~ "Entity name mismatch: names differ"
    assert findings =~ "Tax ID failed validation"
    assert findings =~ "Sanctions screening hit: watchlist"
  end

  test "describe_findings is empty when everything passes" do
    assert Checks.describe_findings(validation(%{})) == ""
  end

  test "validate combines the entity match and both tool calls" do
    stub_defaults(screen_vendor: fn _name -> {:ok, %{flagged: true, reason: "watchlist"}} end)

    assert {:ok, result} = Checks.validate(%{contract: contract(), w9: w9()})
    assert result.entity_match.match
    assert result.tax_id_valid
    assert result.sanctions_flagged
    assert result.sanctions_reason == "watchlist"
    refute ValidationResult.approved?(result)
  end

  test "validate propagates a tool failure instead of approving" do
    stub_defaults(validate_tax_id: fn _tax_id -> {:error, :tool_unavailable} end)

    assert {:error, :tool_unavailable} = Checks.validate(%{contract: contract(), w9: w9()})
  end
end
