defmodule VendorOnboarding.Repository do
  @moduledoc """
  The only module that touches `VendorOnboarding.Repo` directly.
  No coordination, no HTTP calls — pure persistence.
  """

  import Ecto.Query

  alias VendorOnboarding.Repo
  alias VendorOnboarding.Schema.VendorOnboarding, as: Schema

  @spec get_by_idempotency_key(String.t()) :: Schema.t() | nil
  def get_by_idempotency_key(idempotency_key) do
    Repo.get_by(Schema, idempotency_key: idempotency_key)
  end

  @spec insert(map()) :: {:ok, Schema.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %Schema{}
    |> Schema.ingest_changeset(attrs)
    |> Repo.insert()
  end

  @spec get(pos_integer()) :: {:ok, Schema.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(Schema, id) do
      nil -> {:error, :not_found}
      onboarding -> {:ok, onboarding}
    end
  end

  @spec get!(pos_integer()) :: Schema.t()
  def get!(id), do: Repo.get!(Schema, id)

  @spec update_agent_result(Schema.t(), map()) ::
          {:ok, Schema.t()} | {:error, Ecto.Changeset.t()}
  def update_agent_result(%Schema{} = onboarding, attrs) do
    onboarding
    |> Schema.agent_result_changeset(attrs)
    |> Repo.update()
  end

  @spec list(keyword()) :: [Schema.t()]
  def list(opts \\ []) do
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 50)

    Schema
    |> maybe_filter_status(status)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, status: ^status)
end
