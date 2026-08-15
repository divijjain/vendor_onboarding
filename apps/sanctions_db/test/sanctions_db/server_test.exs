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
end
