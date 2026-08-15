defmodule VendorOnboarding.Repo.Migrations.CreateRunCheckpoints do
  @moduledoc """
  The agent pipeline's checkpoint table — a halted-and-serialized Reactor
  struct plus everything needed to resume it. Lives in its own
  `agent_checkpoints` Postgres schema (not `public`, not alongside the
  business-domain tables) even though it shares this app's Repo now — same
  "don't let checkpoint tables leak into business-domain migrations" rule
  as when this lived in a separate `agent_service` application.
  """

  use Ecto.Migration

  def change do
    execute "CREATE SCHEMA IF NOT EXISTS agent_checkpoints",
            "DROP SCHEMA IF EXISTS agent_checkpoints"

    create table(:run_checkpoints, prefix: "agent_checkpoints") do
      add :thread_id, :string, null: false
      add :onboarding_id, :integer, null: false

      # The :erlang.term_to_binary/1-serialized halted %Reactor{}.
      add :reactor_state, :binary, null: false
      # Reactor.run/3 rejects a resume that doesn't re-supply every
      # original input, so they're persisted alongside the halted struct.
      add :inputs, :map, null: false, default: %{}
      add :explanation, :text

      add :status, :string, null: false, default: "awaiting_review"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:run_checkpoints, [:thread_id], prefix: "agent_checkpoints")
    create index(:run_checkpoints, [:onboarding_id], prefix: "agent_checkpoints")
  end
end
