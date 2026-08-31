defmodule DocumentComplianceEngine.Agent.FormatValidatorsTest do
  use ExUnit.Case, async: true

  alias DocumentComplianceEngine.Agent.FormatValidators

  defp valid?(validator, value), do: FormatValidators.validate(validator, value) == :ok

  describe "checksum validators reject right-shaped values that aren't real identifiers" do
    # The point of these three: a regex alone would accept every "invalid"
    # case below. They are what makes a format rule more than a shape check.

    test "iban runs the ISO 13616 mod-97 checksum" do
      assert valid?("iban", "GB82 WEST 1234 5698 7654 32")
      assert valid?("iban", "GB82WEST12345698765432")
      assert valid?("iban", "DE89370400440532013000")

      # Correct country, length and shape — one digit altered.
      refute valid?("iban", "GB82WEST12345698765433")
      refute valid?("iban", "DE89370400440532013001")
      refute valid?("iban", "not an iban")
    end

    test "credit_card runs Luhn" do
      assert valid?("credit_card", "4242424242424242")
      assert valid?("credit_card", "4242 4242 4242 4242")
      assert valid?("credit_card", "5555-5555-5555-4444")

      # Right length, right shape, fails Luhn.
      refute valid?("credit_card", "4242424242424243")
      refute valid?("credit_card", "1234567812345678")
    end

    test "vin runs the ISO 3779 check digit" do
      assert valid?("vin", "1HGBH41JXMN109186")
      assert valid?("vin", "1hgbh41jxmn109186")

      # Check digit (position 9) deliberately wrong.
      refute valid?("vin", "1HGBH41J1MN109186")
      # I, O and Q are excluded from the VIN alphabet.
      refute valid?("vin", "1HGBH41JXMN10918O")
      refute valid?("vin", "TOOSHORT")
    end
  end

  describe "structural validators" do
    test "date accepts real calendar dates in several notations" do
      assert valid?("date", "2026-03-14")
      assert valid?("date", "14/03/2026")
      assert valid?("date", "03/14/2026")
      assert valid?("date", "2026/03/14")
      assert valid?("date", "March 14, 2026")
      assert valid?("date", "14 Mar 2026")
    end

    test "date rejects impossible calendar dates, not just malformed ones" do
      refute valid?("date", "2026-02-30")
      refute valid?("date", "2026-13-01")
      refute valid?("date", "32/01/2026")
      refute valid?("date", "sometime next spring")
    end

    test "number accepts thousands separators and rejects trailing junk" do
      assert valid?("number", "42")
      assert valid?("number", "1,234.56")
      assert valid?("number", "-17.5")

      refute valid?("number", "12 items")
      refute valid?("number", "")
      refute valid?("number", "N/A")
    end

    test "email checks shape only" do
      assert valid?("email", "ap@acme-corp.com")
      assert valid?("email", "a.b+tag@sub.example.co.uk")

      refute valid?("email", "acme-corp.com")
      refute valid?("email", "two words@example.com")
      refute valid?("email", "no@tld")
    end

    test "uri requires a scheme and a host" do
      assert valid?("uri", "https://acme-corp.com/invoices")

      refute valid?("uri", "acme-corp.com")
      refute valid?("uri", "/just/a/path")
    end

    test "phone counts digits within E.164 bounds" do
      assert valid?("phone", "+1 (415) 555-0142")
      assert valid?("phone", "020 7946 0958")

      refute valid?("phone", "555")
      refute valid?("phone", "+1 415 555 0142 ext. 12 please call after 5")
    end

    test "vat_id checks the country-prefixed shape" do
      assert valid?("vat_id", "DE123456789")
      assert valid?("vat_id", "NL123456789B01")
      assert valid?("vat_id", "GB123456789")

      refute valid?("vat_id", "DE12345")
      refute valid?("vat_id", "123456789")
    end

    test "currency accepts ISO codes, symbols, and symbol-prefixed amounts" do
      assert valid?("currency", "USD")
      assert valid?("currency", "eur")
      assert valid?("currency", "€")
      assert valid?("currency", "$1,250.00")

      refute valid?("currency", "dollars")
      refute valid?("currency", "XYZ")
    end

    test "postal_address applies a plausibility heuristic, and says so" do
      assert valid?("postal_address", "123 Market St, San Francisco, CA 94103")

      refute valid?("postal_address", "Acme")
      refute valid?("postal_address", "no numbers here at all")
    end
  end

  describe "contract" do
    test "an unknown validator name is a config bug, not a failed check" do
      assert FormatValidators.validate("blockchain_integrity", "anything") ==
               {:error, :unknown_validator}
    end

    test "a failure carries a reviewer-readable detail" do
      assert {:error, detail} = FormatValidators.validate("iban", "GB82WEST12345698765433")
      assert detail =~ "mod-97"
      assert detail =~ "GB82WEST12345698765433"
    end

    test "known/0 lists exactly the validators validate/2 dispatches on" do
      assert length(FormatValidators.known()) == 11

      for validator <- FormatValidators.known() do
        refute FormatValidators.validate(validator, "some value") == {:error, :unknown_validator}
      end
    end
  end
end
