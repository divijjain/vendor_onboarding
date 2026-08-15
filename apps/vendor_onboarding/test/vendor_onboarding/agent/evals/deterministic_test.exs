defmodule VendorOnboarding.Agent.Evals.DeterministicTest do
  use ExUnit.Case, async: true

  alias VendorOnboarding.Agent.Evals.Deterministic

  @source "2. Taxpayer Identification Number (EIN): 12-3456789\n"

  test "passes when the extracted tax id appears verbatim in the source" do
    assert Deterministic.tax_id_verbatim?("12-3456789", @source)
  end

  test "tolerates surrounding whitespace on the extracted value" do
    assert Deterministic.tax_id_verbatim?("  12-3456789  ", @source)
  end

  test "fails on a hallucinated tax id that is not in the source" do
    refute Deterministic.tax_id_verbatim?("99-9999999", @source)
  end

  test "fails on an empty or absent extraction" do
    refute Deterministic.tax_id_verbatim?("", @source)
    refute Deterministic.tax_id_verbatim?("   ", @source)
    refute Deterministic.tax_id_verbatim?(nil, @source)
  end
end
