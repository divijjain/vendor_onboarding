defmodule DocumentComplianceEngine.Agent.Evals.FixturesTest do
  use ExUnit.Case, async: true

  alias DocumentComplianceEngine.Agent.Evals.Fixtures

  test "the suite is the deliberate 20-document, four-bucket structure" do
    fixtures = Fixtures.all()
    counts = Enum.frequencies_by(fixtures, & &1.bucket)

    assert length(fixtures) == 20
    assert counts == %{"clean" => 10, "mismatch" => 5, "formatting" => 3, "malformed" => 2}
  end

  test "fixture ids are unique" do
    ids = Enum.map(Fixtures.all(), & &1.id)
    assert length(Enum.uniq(ids)) == 20
  end

  test "every fixture embeds its names and tax id in the document text" do
    for fixture <- Fixtures.all() do
      assert fixture.contract_text =~ "VENDOR SERVICES AGREEMENT"
      assert fixture.w9_text =~ "Taxpayer Identification Number"
    end
  end

  test "buckets carry the decision the pipeline is expected to reach" do
    by_bucket = Enum.group_by(Fixtures.all(), & &1.bucket)

    assert Enum.all?(by_bucket["clean"], &(&1.expected_decision == "approved"))
    assert Enum.all?(by_bucket["formatting"], &(&1.expected_decision == "approved"))
    assert Enum.all?(by_bucket["mismatch"], &(&1.expected_decision == "needs_review"))
    assert Enum.all?(by_bucket["malformed"], &(&1.expected_decision == "needs_review"))

    # The formatting bucket is the false-positive control: cosmetically
    # different names that are still the same entity.
    assert Enum.all?(by_bucket["formatting"], &(&1.expected_entity_match == true))
    assert Enum.all?(by_bucket["mismatch"], &(&1.expected_entity_match == false))
    # Entity match is not a meaningful expectation for malformed docs.
    assert Enum.all?(by_bucket["malformed"], &is_nil(&1.expected_entity_match))
  end
end
