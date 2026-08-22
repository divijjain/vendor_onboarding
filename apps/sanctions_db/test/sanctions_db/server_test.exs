defmodule SanctionsDb.ServerTest do
  use ExUnit.Case, async: true

  alias SanctionsDb.Server

  test "flags a watchlisted vendor with a reason" do
    assert %{flagged: true, reason: reason} = Server.screen("Rogue Exports LLC")
    assert reason == "Matched sanctions watchlist entry"
  end

  test "matching is case- and whitespace-insensitive" do
    assert %{flagged: true} = Server.screen("  NORTH STAR TRADING CO ")
  end

  test "clears a vendor that is not on the watchlist" do
    assert Server.screen("Acme Corp") == %{flagged: false, reason: nil}
  end

  describe "fuzzy match — real evasion attempts found via adversarial testing" do
    # Every one of these previously sailed through the old exact-match-only
    # check to `flagged: false`, and from there to full pipeline
    # auto-approval with zero human review — see CONTEXT.md's dated entry.
    @evasion_attempts [
      {"extra internal whitespace", "Rogue  Exports LLC"},
      {"a middle initial", "Rogue R. Exports LLC"},
      {"a trailing period", "Rogue Exports LLC."},
      {"a comma variant", "Rogue Exports, LLC"},
      {"a Cyrillic \"о\" homoglyph", "Rоge Exports LLC"},
      {"an inserted word", "Rogue Global Exports LLC"}
    ]

    for {label, name} <- @evasion_attempts do
      test "flags #{label} (#{inspect(name)}) instead of silently clearing it" do
        assert %{flagged: true, reason: reason} = Server.screen(unquote(name))

        assert reason =~ "flagged for manual review" or
                 reason == "Matched sanctions watchlist entry"
      end
    end

    test "a genuinely unrelated company is still cleared, not swept up by the fuzzy match" do
      assert Server.screen("Golden Gate Supplies Co.") == %{flagged: false, reason: nil}
    end

    test "an exact match (after normalization) still gets the certain-hit reason, not the fuzzy one" do
      assert Server.screen("  ROGUE EXPORTS, LLC.  ") == %{
               flagged: true,
               reason: "Matched sanctions watchlist entry"
             }
    end

    test "a fuzzy (non-exact) match reports its similarity score, not a false certainty" do
      assert %{flagged: true, reason: reason} = Server.screen("Rogue Global Exports LLC")
      assert reason =~ ~r/Possible sanctions watchlist match \(name similarity 0\.\d+\)/
    end
  end
end
