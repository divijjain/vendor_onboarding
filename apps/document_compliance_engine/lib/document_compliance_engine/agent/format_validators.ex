defmodule DocumentComplianceEngine.Agent.FormatValidators do
  @moduledoc """
  Pure, deterministic format/integrity checks on a single extracted value —
  no LLM, no MCP, no network, no clock. Called from `Checks`'s `"format"`
  rule clause; a document type opts a field in by naming a validator in its
  `validation_rules`.

  These answer a *different* question from `Checks.grounded_extraction_checks/3`,
  and neither subsumes the other. Grounding asks "did this value come from the
  source document, or did the model invent it?" These ask "is this value
  well-formed for what it claims to be?" A hallucinated IBAN with a correct
  mod-97 checksum passes `iban` and fails grounding; a genuine, verbatim-quoted
  typo in the source passes grounding and fails `iban`. Both checks are cheap,
  so a field can carry both.

  Where a real algorithmic check exists it is implemented properly, not
  approximated by a regex: `iban` runs the ISO 13616 mod-97 checksum,
  `credit_card` runs Luhn, `vin` runs the ISO 3779 check digit. Those three
  genuinely reject a value that is the right shape but not a real identifier.

  The rest are honestly weaker and are named for what they actually do:

    - `email`, `uri`, `phone`, `vat_id` are *structural* checks. A
      syntactically valid email address may not be deliverable and this
      never finds out; `vat_id` checks the country-prefixed shape, not the
      registry (that is what an MCP tool rule is for).
    - `postal_address` is the weakest of the set — a genuine address check
      needs a geocoding service, which would make this module neither pure
      nor free. It applies a structural plausibility heuristic only, and is
      deliberately documented as such rather than named to imply more.

  Returning `{:error, detail}` yields a *failed check*, not a failed run —
  the caller turns it into the same `%{rule:, passed:, detail:}` shape every
  other check produces, so a format failure routes to human review exactly
  like an entity mismatch does.
  """

  @currency_codes ~w(
    AED AUD BRL CAD CHF CNY CZK DKK EUR GBP HKD HUF IDR ILS INR JPY KRW MXN
    MYR NOK NZD PHP PLN RON SEK SGD THB TRY USD ZAR
  )

  @currency_symbols ~w(€ $ £ ¥ ₹ ₩ ₽ ₪ ﷼)

  # Country-prefixed VAT shapes for the jurisdictions this project actually
  # sees. An unlisted prefix falls back to the generic two-letter-plus-body
  # shape rather than rejecting outright — a wrong "invalid" on a valid
  # foreign VAT ID is worse here than a permissive pass, since the MCP
  # registry rules are what authoritatively confirm one.
  @vat_patterns %{
    "AT" => ~r/^ATU[0-9]{8}$/,
    "BE" => ~r/^BE[01][0-9]{9}$/,
    "DE" => ~r/^DE[0-9]{9}$/,
    "DK" => ~r/^DK[0-9]{8}$/,
    "ES" => ~r/^ES[A-Z0-9][0-9]{7}[A-Z0-9]$/,
    "FR" => ~r/^FR[A-Z0-9]{2}[0-9]{9}$/,
    "GB" => ~r/^GB([0-9]{9}|[0-9]{12}|GD[0-9]{3}|HA[0-9]{3})$/,
    "IE" => ~r/^IE[0-9][A-Z0-9+*][0-9]{5}[A-Z]$/,
    "IT" => ~r/^IT[0-9]{11}$/,
    "NL" => ~r/^NL[0-9]{9}B[0-9]{2}$/,
    "PL" => ~r/^PL[0-9]{10}$/,
    "PT" => ~r/^PT[0-9]{9}$/,
    "SE" => ~r/^SE[0-9]{12}$/
  }

  # ISO 3779: I, O and Q are excluded from VINs precisely because they are
  # confusable with 1 and 0.
  @vin_transliteration %{
    ?A => 1,
    ?B => 2,
    ?C => 3,
    ?D => 4,
    ?E => 5,
    ?F => 6,
    ?G => 7,
    ?H => 8,
    ?J => 1,
    ?K => 2,
    ?L => 3,
    ?M => 4,
    ?N => 5,
    ?P => 7,
    ?R => 9,
    ?S => 2,
    ?T => 3,
    ?U => 4,
    ?V => 5,
    ?W => 6,
    ?X => 7,
    ?Y => 8,
    ?Z => 9
  }

  @vin_weights [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]

  @validators ~w(
    date number email phone iban vat_id postal_address currency uri
    credit_card vin
  )

  @doc "Every validator name a `\"format\"` rule may name."
  @spec known() :: [String.t()]
  def known, do: @validators

  @doc """
  Checks `value` against the named validator. `{:error, detail}` carries a
  human-readable reason for the reviewer, in the same voice as the other
  check details. An unrecognized validator name is `{:error, :unknown_validator}`
  — a config bug the caller should surface loudly, not a failed check.
  """
  @spec validate(String.t(), String.t()) ::
          :ok | {:error, String.t()} | {:error, :unknown_validator}
  def validate(validator, value) when is_binary(validator) and is_binary(value) do
    trimmed = String.trim(value)

    case validator do
      "date" -> check(date?(trimmed), trimmed, "a valid date")
      "number" -> check(number?(trimmed), trimmed, "a valid number")
      "email" -> check(email?(trimmed), trimmed, "a valid email address")
      "phone" -> check(phone?(trimmed), trimmed, "a valid phone number")
      "iban" -> check(iban?(trimmed), trimmed, "a valid IBAN (mod-97 checksum)")
      "vat_id" -> check(vat_id?(trimmed), trimmed, "a valid VAT ID")
      "postal_address" -> check(postal_address?(trimmed), trimmed, "a plausible postal address")
      "currency" -> check(currency?(trimmed), trimmed, "a valid currency")
      "uri" -> check(uri?(trimmed), trimmed, "a valid URI")
      "credit_card" -> check(credit_card?(trimmed), trimmed, "a valid card number (Luhn)")
      "vin" -> check(vin?(trimmed), trimmed, "a valid VIN (ISO 3779 check digit)")
      _unknown -> {:error, :unknown_validator}
    end
  end

  defp check(true, _value, _expectation), do: :ok

  defp check(false, value, expectation),
    do: {:error, "#{inspect(value)} is not #{expectation}."}

  # --- date -----------------------------------------------------------------

  # Parseability only. A slash-separated date is tried both day-first and
  # month-first and accepted if *either* is a real calendar date — this
  # checks that a date exists, deliberately not which locale wrote it.
  defp date?(value) do
    iso8601?(value) or slash_or_dash_date?(value) or textual_month_date?(value)
  end

  defp iso8601?(value) do
    match?({:ok, _date}, Date.from_iso8601(value))
  end

  defp slash_or_dash_date?(value) do
    case Regex.run(~r|^(\d{1,4})[/-](\d{1,2})[/-](\d{1,4})$|, value) do
      [_all, a, b, c] ->
        [a, b, c] = Enum.map([a, b, c], &String.to_integer/1)
        valid_date?(c, b, a) or valid_date?(c, a, b) or valid_date?(a, b, c)

      nil ->
        false
    end
  end

  @months ~w(january february march april may june july august september october november december)

  defp textual_month_date?(value) do
    downcased = String.downcase(value)

    Enum.any?(@months, &String.contains?(downcased, String.slice(&1, 0, 3))) and
      Regex.match?(~r/\b\d{1,2}\b/, value) and Regex.match?(~r/\b\d{4}\b/, value)
  end

  defp valid_date?(year, month, day) when year > 31 do
    match?({:ok, _date}, Date.new(year, month, day))
  end

  defp valid_date?(_year, _month, _day), do: false

  # --- number ---------------------------------------------------------------

  defp number?(value) do
    cleaned = value |> String.replace(",", "") |> String.replace(" ", "")

    match?({_parsed, ""}, Float.parse(cleaned)) or match?({_parsed, ""}, Integer.parse(cleaned))
  end

  # --- email / uri / phone --------------------------------------------------

  defp email?(value), do: Regex.match?(~r/^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/, value)

  defp uri?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) -> host != ""
      _uri -> false
    end
  end

  # E.164 caps a subscriber number at 15 digits; 7 is the shortest number
  # plausibly written on a business document.
  defp phone?(value) do
    digits = String.replace(value, ~r/[^\d]/, "")

    Regex.match?(~r/^\+?[\d\s().\-]+$/, value) and String.length(digits) in 7..15
  end

  # --- iban -----------------------------------------------------------------

  defp iban?(value) do
    normalized = value |> String.replace(~r/\s/, "") |> String.upcase()

    Regex.match?(~r/^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$/, normalized) and iban_checksum?(normalized)
  end

  defp iban_checksum?(iban) do
    {head, tail} = String.split_at(iban, 4)

    (tail <> head)
    |> String.to_charlist()
    |> Enum.map_join(fn
      char when char in ?0..?9 -> <<char>>
      char when char in ?A..?Z -> Integer.to_string(char - ?A + 10)
    end)
    |> String.to_integer()
    |> rem(97) == 1
  end

  # --- vat_id ---------------------------------------------------------------

  defp vat_id?(value) do
    normalized = value |> String.replace(~r/[\s.\-]/, "") |> String.upcase()

    case @vat_patterns[String.slice(normalized, 0, 2)] do
      nil -> Regex.match?(~r/^[A-Z]{2}[A-Z0-9]{2,13}$/, normalized)
      pattern -> Regex.match?(pattern, normalized)
    end
  end

  # --- currency -------------------------------------------------------------

  defp currency?(value) do
    upcased = String.upcase(value)

    upcased in @currency_codes or value in @currency_symbols or
      Enum.any?(@currency_symbols, &String.starts_with?(value, &1)) or
      Enum.any?(@currency_codes, &String.starts_with?(upcased, &1 <> " "))
  end

  # --- postal_address -------------------------------------------------------

  # Structural plausibility only — see the moduledoc. Requires a number
  # (street or postal code), at least three whitespace-separated tokens, and
  # enough length to not be a stray fragment.
  defp postal_address?(value) do
    String.length(value) >= 8 and Regex.match?(~r/\d/, value) and
      length(String.split(value, ~r/\s+/, trim: true)) >= 3
  end

  # --- credit_card ----------------------------------------------------------

  defp credit_card?(value) do
    digits = String.replace(value, ~r/[\s\-]/, "")

    Regex.match?(~r/^\d{12,19}$/, digits) and luhn?(digits)
  end

  defp luhn?(digits) do
    digits
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {char, index}, sum -> sum + luhn_digit(char - ?0, index) end)
    |> rem(10) == 0
  end

  defp luhn_digit(digit, index) when rem(index, 2) == 1 and digit * 2 > 9, do: digit * 2 - 9
  defp luhn_digit(digit, index) when rem(index, 2) == 1, do: digit * 2
  defp luhn_digit(digit, _index), do: digit

  # --- vin ------------------------------------------------------------------

  defp vin?(value) do
    normalized = String.upcase(value)

    Regex.match?(~r/^[A-HJ-NPR-Z0-9]{17}$/, normalized) and vin_check_digit?(normalized)
  end

  defp vin_check_digit?(vin) do
    chars = String.to_charlist(vin)

    sum =
      chars
      |> Enum.zip(@vin_weights)
      |> Enum.reduce(0, fn {char, weight}, acc -> acc + vin_value(char) * weight end)

    expected = rem(sum, 11)
    actual = Enum.at(chars, 8)

    (expected == 10 and actual == ?X) or
      (expected < 10 and actual == ?0 + expected)
  end

  defp vin_value(char) when char in ?0..?9, do: char - ?0
  defp vin_value(char), do: Map.fetch!(@vin_transliteration, char)
end
