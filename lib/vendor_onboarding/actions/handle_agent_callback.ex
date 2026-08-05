defmodule VendorOnboarding.Actions.HandleAgentCallback do
  @moduledoc """
  Writes an agent run's result back onto the row and broadcasts the update
  via PubSub so the (future) LiveView dashboard can react. Called from
  `AgentCallbackController`.
  """

  alias VendorOnboarding.Repository

  @result_fields ~w(status thread_id company_name tax_id payment_terms liability_clauses explanation)

  @spec call(map()) ::
          {:ok, VendorOnboarding.Schema.VendorOnboarding.t()}
          | {:error, :not_found | Ecto.Changeset.t()}
  def call(%{"onboarding_id" => onboarding_id} = params) do
    with {:ok, onboarding} <- Repository.get(onboarding_id),
         {:ok, updated} <- Repository.update_agent_result(onboarding, result_attrs(params)) do
      Phoenix.PubSub.broadcast(
        VendorOnboarding.PubSub,
        "vendor_onboarding",
        {:status_updated, updated.id}
      )

      {:ok, updated}
    end
  end

  defp result_attrs(params) do
    params
    |> Map.take(@result_fields)
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end
end
