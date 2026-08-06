defmodule VendorOnboarding.Onboardings.Repository do
  @moduledoc """
  The only module that touches `VendorOnboarding.Repo` for the `onboardings`
  table. No coordination, no HTTP calls, no reaching into `AgentRuns`.
  """

  import Ecto.Query

  alias VendorOnboarding.Repo
  alias VendorOnboarding.Onboardings.Schema.Onboarding

  @spec get_by_idempotency_key(String.t()) :: Onboarding.t() | nil
  def get_by_idempotency_key(idempotency_key) do
    Repo.get_by(Onboarding, idempotency_key: idempotency_key)
  end

  @spec insert(map()) :: {:ok, Onboarding.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %Onboarding{}
    |> Onboarding.ingest_changeset(attrs)
    |> Repo.insert()
  end

  @spec get(pos_integer()) :: {:ok, Onboarding.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(Onboarding, id) do
      nil -> {:error, :not_found}
      onboarding -> {:ok, onboarding}
    end
  end

  @spec get!(pos_integer()) :: Onboarding.t()
  def get!(id), do: Repo.get!(Onboarding, id)

  @spec update_status(pos_integer(), atom()) ::
          {:ok, Onboarding.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_status(id, status) do
    with {:ok, onboarding} <- get(id) do
      onboarding
      |> Onboarding.status_changeset(status)
      |> Repo.update()
    end
  end

  @spec list(keyword()) :: [Onboarding.t()]
  def list(opts \\ []) do
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 50)

    Onboarding
    |> maybe_filter_status(status)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, status: ^status)
end
