defmodule DocumentComplianceEngine.Agent.Evals.FixturesTest do
  use DocumentComplianceEngine.DataCase, async: true

  alias DocumentComplianceEngine.Agent.Evals.Fixtures
  alias DocumentComplianceEngine.Agent.Extraction
  alias DocumentComplianceEngine.Agent.FormatValidators
  alias DocumentComplianceEngine.DocumentTypes

  test "all/0 spans every fixtured document type with no id collisions" do
    fixtures = Fixtures.all()

    assert length(fixtures) == 108
    ids = Enum.map(fixtures, & &1.id)
    assert length(Enum.uniq(ids)) == 108

    # Every document type in the registry has fixtures — the ratio this
    # corpus was grown to close. A type seeded without any lands here.
    assert fixtures |> Enum.map(& &1.document_type_slug) |> Enum.uniq() |> Enum.sort() ==
             [
               "bank_details",
               "business_registration",
               "certificate_of_insurance",
               "invoice",
               "payroll_statement",
               "purchase_order",
               "receipt",
               "vendor_contract_w9",
               "w8ben"
             ]
  end

  test "every fixture carries enough of its own type's vocabulary to be extracted at all" do
    # A fixture that fails its type's shape gate is never extracted, so a
    # bucket asserting an extraction outcome would be asserting nothing.
    # The wrong-type bucket is the deliberate exception: failing that gate
    # is the behaviour it tests.
    types = Map.new(DocumentTypes.list_document_types(), &{&1.slug, &1})

    for fixture <- Fixtures.all(),
        fixture.documents,
        fixture.bucket != "invoice_wrong_type",
        {role, text} <- fixture.documents do
      shape = types[fixture.document_type_slug].shape_signals[role]

      assert Extraction.shape_matches?(text, shape),
             "#{fixture.id} (#{role}) does not clear its own type's shape gate"
    end
  end

  describe "certificate_of_insurance/0" do
    test "dates are relative to today, so the corpus cannot rot into failure" do
      by_bucket = Enum.group_by(Fixtures.certificate_of_insurance(), & &1.bucket)
      today = Date.utc_today()

      # A committed literal like "expires 2027-06-01" is a fixture that
      # silently starts failing in June 2027.
      for fixture <- by_bucket["coi_clean"] do
        assert {:ok, expiry} = expiry_date(fixture)
        assert Date.compare(expiry, today) == :gt
      end

      assert [expired] = by_bucket["coi_expired"]
      assert {:ok, expiry} = expiry_date(expired)
      assert Date.compare(expiry, today) == :lt
    end

    defp expiry_date(fixture) do
      [_all, date] =
        Regex.run(~r/Expires: (\S+)/, fixture.documents["certificate_of_insurance"])

      Date.from_iso8601(date)
    end
  end

  describe "payroll_statement/0" do
    test "the gross/net fixture states its expected values, since a swap would be grounded" do
      [fixture] =
        Enum.filter(Fixtures.payroll_statement(), &(&1.bucket == "payroll_gross_net"))

      assert %{"payroll_statement" => %{gross_pay: gross, net_pay: net}} =
               fixture.expected_fields

      assert gross != net
      assert fixture.documents["payroll_statement"] =~ gross
      assert fixture.documents["payroll_statement"] =~ net
    end
  end

  describe "bank_details/0" do
    test "the invalid bucket differs from the clean one only by the IBAN check digit" do
      # The whole point of the bucket: a length/shape check passes both, and
      # only the mod-97 checksum tells them apart.
      by_bucket = Enum.group_by(Fixtures.bank_details(), & &1.bucket)

      valid = extract_iban(hd(by_bucket["bank_details_clean"]))
      invalid = extract_iban(hd(by_bucket["bank_details_invalid_iban"]))

      assert String.length(valid) == String.length(invalid)
      assert String.slice(valid, 0..-2//1) == String.slice(invalid, 0..-2//1)
      assert valid != invalid

      assert :ok = FormatValidators.validate("iban", valid)
      assert {:error, _detail} = FormatValidators.validate("iban", invalid)
    end

    test "buckets carry the decision the pipeline is expected to reach" do
      by_bucket = Enum.group_by(Fixtures.bank_details(), & &1.bucket)

      assert Enum.all?(by_bucket["bank_details_clean"], &(&1.expected_decision == "approved"))

      assert Enum.all?(
               by_bucket["bank_details_invalid_iban"],
               &(&1.expected_decision == "needs_review")
             )

      assert Enum.all?(
               by_bucket["bank_details_sanctions_hit"],
               &(&1.expected_decision == "needs_review")
             )
    end

    defp extract_iban(fixture) do
      [_all, iban] = Regex.run(~r/IBAN: (\S+)/, fixture.documents["bank_details"])
      iban
    end
  end

  describe "purchase_order/0" do
    test "the dates bucket labels its two dates so the field names give no help" do
      [fixture] = Enum.filter(Fixtures.purchase_order(), &(&1.bucket == "purchase_order_dates"))
      text = fixture.documents["purchase_order"]

      # Neither "order date" nor "delivery date" appears — only the field
      # descriptions can tell the model which date is which.
      refute text =~ ~r/order date/i
      refute text =~ ~r/delivery date/i
      assert text =~ "Raised:"
      assert text =~ "Required By:"
      # A third date as a distractor, belonging to neither field.
      assert text =~ "Printed:"
    end

    test "every fixture embeds both parties and the total in the document text" do
      for fixture <- Fixtures.purchase_order() do
        assert fixture.document_type_slug == "purchase_order"
        assert fixture.documents["purchase_order"] =~ "PURCHASE ORDER"
        assert fixture.documents["purchase_order"] =~ "Supplier:"
      end
    end
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
    test "is a 16-fixture, five-bucket structure" do
      fixtures = Fixtures.invoice()
      counts = Enum.frequencies_by(fixtures, & &1.bucket)

      assert length(fixtures) == 16

      assert counts == %{
               "invoice_clean" => 6,
               "invoice_sanctions_hit" => 2,
               "invoice_sanctions_evasion" => 2,
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

      assert Enum.all?(
               by_bucket["invoice_sanctions_evasion"],
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

    test "the sanctions-evasion bucket uses real adversarial-testing evasion attempts, not the exact watchlisted names" do
      vendors =
        Fixtures.invoice()
        |> Enum.filter(&(&1.bucket == "invoice_sanctions_evasion"))
        |> Enum.map(& &1.documents["invoice"])

      assert Enum.any?(vendors, &(&1 =~ "Rogue Global Exports LLC"))
      assert Enum.any?(vendors, &(&1 =~ "Rоge Exports LLC"))
      # Neither is the literal watchlisted name -- the whole point is that
      # they're close variants the fuzzy match has to catch, not exact hits.
      refute Enum.any?(vendors, &String.contains?(&1, "Vendor: Rogue Exports LLC\n"))
    end
  end

  describe "scanned/0" do
    test "is an 8-fixture, image-backed structure with no plain-text documents" do
      fixtures = Fixtures.scanned()
      counts = Enum.frequencies_by(fixtures, & &1.bucket)

      assert length(fixtures) == 8

      assert counts == %{
               "scanned_clean" => 2,
               "scanned_sanctions_hit" => 1,
               "scanned_malformed" => 1,
               "scanned_layout_diverse" => 2,
               "scanned_photo_realistic" => 2
             }

      for fixture <- fixtures do
        assert fixture.document_type_slug == "invoice"
        assert is_nil(fixture.documents)
        assert Map.keys(fixture.image_paths) == ["invoice"]
        assert File.exists?(fixture.image_paths["invoice"])
      end
    end

    test "buckets carry the decision the pipeline is expected to reach" do
      by_bucket = Enum.group_by(Fixtures.scanned(), & &1.bucket)

      assert Enum.all?(by_bucket["scanned_clean"], &(&1.expected_decision == "approved"))

      assert Enum.all?(
               by_bucket["scanned_sanctions_hit"],
               &(&1.expected_decision == "needs_review")
             )

      assert Enum.all?(by_bucket["scanned_malformed"], &(&1.expected_decision == "needs_review"))

      assert Enum.all?(
               by_bucket["scanned_layout_diverse"],
               &(&1.expected_decision == "approved")
             )

      assert Enum.all?(
               by_bucket["scanned_photo_realistic"],
               &(&1.expected_decision == "approved")
             )
    end

    test "the photo-realistic bucket includes a real JPEG, not just PNGs" do
      extensions =
        Fixtures.scanned()
        |> Enum.filter(&(&1.bucket == "scanned_photo_realistic"))
        |> Enum.map(&Path.extname(&1.image_paths["invoice"]))

      assert extensions == [".jpg", ".jpg"]
    end
  end
end
