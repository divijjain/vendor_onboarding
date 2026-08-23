defmodule DocumentComplianceEngine.Repo.Migrations.CreateUsers do
  @moduledoc """
  Accounts for Google sign-in. A row can exist before its owner ever logs
  in — a webhook's `owner_email` auto-provisions by email alone, with
  `google_sub` left `nil` — and gets linked to a real Google account (its
  `google_sub` set) the first time that email successfully signs in. Both
  unique indexes are safe as plain (non-partial) indexes: Postgres treats
  every `NULL` as distinct from every other `NULL`, so any number of
  not-yet-linked rows can coexist with `google_sub: nil`.
  """

  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :google_sub, :string
      add :name, :string
      add :avatar_url, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:google_sub])
  end
end
