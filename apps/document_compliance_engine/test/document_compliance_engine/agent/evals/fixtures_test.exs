defmodule DocumentComplianceEngine.Agent.Evals.FixturesTest do
  use ExUnit.Case, async: true

  alias DocumentComplianceEngine.Agent.Evals.Fixtures

  test "all/0 spans both document types with no id collisions" do
    fixtures = Fixtures.all()

    assert length(fixtures) == 69
    ids = Enum.map(fixtures, & &1.id)
    assert length(Enum.uniq(ids)) == 69
  end

  describe "vendor_contract_w9/0" do
    test "is the deliberate 55-document, four-bucket structure" do
      fixtures = Fixtures.vendor_contract_w9()
      counts = Enum.frequencies_by(fixtures, & &1.bucket)

      assert length(fixtures) == 55
      assert counts == %{"clean" => 20, "mismatch" => 15, "formatting" => 12, "malformed" => 8}
    end

    test "every fixture embeds its names and tax id in the document text" do
      for fixture <- Fixtures.vendor_contract_w9() do
        assert fixture.document_type_slug == "vendor_contract_w9"
        assert fixture.documents["contract"] =~ "VENDOR SERVICES AGREEMENT"
        assert fixture.documents["w9"] =~ "Taxpayer Identification Number"
      end
    end

    test "buckets carry the decision the pipeline is expected to reach" do
      by_bucket = Enum.group_by(Fixtures.vendor_contract_w9(), & &1.bucket)

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

  describe "invoice/0" do
    test "is a 14-fixture, four-bucket structure" do
      fixtures = Fixtures.invoice()
      counts = Enum.frequencies_by(fixtures, & &1.bucket)

      assert length(fixtures) == 14

      assert counts == %{
               "invoice_clean" => 6,
               "invoice_sanctions_hit" => 2,
               "invoice_malformed" => 3,
               "invoice_wrong_type" => 3
             }
    end

    test "every fixture is a single invoice-role document with no entity-match expectation" do
      for fixture <- Fixtures.invoice() do
        assert fixture.document_type_slug == "invoice"
        assert Map.keys(fixture.documents) == ["invoice"]
        assert is_nil(fixture.expected_entity_match)
      end
    end

    test "buckets carry the decision the pipeline is expected to reach" do
      by_bucket = Enum.group_by(Fixtures.invoice(), & &1.bucket)

      assert Enum.all?(by_bucket["invoice_clean"], &(&1.expected_decision == "approved"))

      assert Enum.all?(
               by_bucket["invoice_sanctions_hit"],
               &(&1.expected_decision == "needs_review")
             )

      assert Enum.all?(by_bucket["invoice_malformed"], &(&1.expected_decision == "needs_review"))
      assert Enum.all?(by_bucket["invoice_wrong_type"], &(&1.expected_decision == "needs_review"))
    end

    test "the sanctions-hit bucket uses the real mock sanctions_db watchlist names verbatim" do
      vendors =
        Fixtures.invoice()
        |> Enum.filter(&(&1.bucket == "invoice_sanctions_hit"))
        |> Enum.map(& &1.documents["invoice"])

      assert Enum.any?(vendors, &(&1 =~ "Rogue Exports LLC"))
      assert Enum.any?(vendors, &(&1 =~ "North Star Trading Co"))
    end
  end
end
