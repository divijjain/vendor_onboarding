defmodule SanctionsDb.Server do
  @moduledoc """
  Mock Sanctions DB — a real, separate process exposing one MCP tool.
  Screens a vendor name against a mock sanctions watchlist: an exact
  normalized match is a certain hit, and a close-but-not-exact match (see
  `@fuzzy_match_threshold`) is flagged for human review rather than
  silently cleared — closes a real evasion gap found via adversarial
  testing (extra whitespace, a middle initial, a homoglyph, an inserted
  word all previously defeated exact-match-only screening). See
  CONTEXT.md's dated entry.
  """

  use Hermes.Server,
    name: "sanctions-db",
    version: "1.0.0",
    capabilities: [:tools]

  alias Hermes.Server.Response

  # Deliberately small and deterministic — this is a mock external system,
  # not a real sanctions feed.
  @sanctioned_names MapSet.new(["rogue exports llc", "north star trading co"])

  # Below this, a name is confidently unrelated to any watchlisted entity.
  # At or above it (but not an exact match), flag for human review rather
  # than silently clearing it. Calibrated against real adversarial testing,
  # not guessed: six realistic evasion attempts against "Rogue Exports LLC"
  # (extra whitespace, a middle initial, a trailing period, a comma
  # variant, a Cyrillic "о" homoglyph, an inserted word) scored 0.805-1.0
  # similarity against their target — every one of them previously sailed
  # through the old exact-match-only check to full auto-approval, with
  # zero human review. An unrelated real company scored 0.618, comfortably
  # separated. See CONTEXT.md's dated entry.
  #
  # Erring toward *more* review triggers is the deliberately safe
  # direction here, unlike `Checks.entity_match/2`'s symmetric thresholds:
  # a false positive here costs one human review (a `needs_review` halt is
  # a pause for a look, not a permanent block); a false negative lets a
  # sanctioned entity through with zero eyes on it at all. A real
  # screening vendor's own fuzzy/phonetic matching is what this stands in
  # for — reusing `Checks.staged_match/2`'s cheap-deterministic-prefilter
  # design, not its exact thresholds (no LLM fallback here: this mock is
  # deliberately deterministic-only, not an agent in its own right).
  @fuzzy_match_threshold 0.80

  @impl true
  def init(_client_info, frame) do
    {:ok,
     register_tool(frame, "screen_vendor",
       input_schema: %{
         company_name: {:required, :string, description: "Vendor company name to screen"}
       },
       annotations: %{read_only: true},
       description: "Screen a vendor's company name against the mock sanctions watchlist."
     )}
  end

  @impl true
  def handle_tool_call("screen_vendor", %{company_name: company_name}, frame) do
    {:reply, Response.json(Response.tool(), screen(company_name)), frame}
  end

  @doc "The watchlist rule itself — pure, so it can be tested without the server."
  @spec screen(String.t()) :: %{flagged: boolean(), reason: String.t() | nil}
  def screen(company_name) do
    normalized = normalize(company_name)

    case best_match(normalized) do
      {_name, similarity} when similarity == 1.0 ->
        %{flagged: true, reason: "Matched sanctions watchlist entry"}

      {_name, similarity} when similarity >= @fuzzy_match_threshold ->
        %{
          flagged: true,
          reason:
            "Possible sanctions watchlist match (name similarity #{Float.round(similarity, 2)}) — flagged for manual review"
        }

      _ ->
        %{flagged: false, reason: nil}
    end
  end

  defp best_match(normalized_name) do
    @sanctioned_names
    |> Enum.map(&{&1, String.jaro_distance(normalized_name, &1)})
    |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0.0} end)
  end

  defp normalize(name) do
    name
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^\w\s]/u, "")
    |> String.replace(~r/\s+/, " ")
  end
end
