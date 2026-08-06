defmodule VendorOnboarding.Actions.ResumeReview do
  @moduledoc """
  Human approval/rejection from the LiveView review screen -> AgentService.resume/1.
  Doesn't write status locally — the Python callback (HandleAgentCallback) is
  still the single writer of final status, keeping one source of truth.
  """

  alias VendorOnboarding.{AgentService, Repository}

  @spec call(pos_integer(), :approved | :rejected) ::
          {:ok, VendorOnboarding.Schema.VendorOnboarding.t()} | {:error, term()}
  def call(onboarding_id, decision) when decision in [:approved, :rejected] do
    with {:ok, onboarding} <- Repository.get(onboarding_id),
         :ok <- ensure_needs_review(onboarding),
         {:ok, _response} <-
           AgentService.resume(%{
             onboarding_id: onboarding.id,
             thread_id: onboarding.thread_id,
             decision: Atom.to_string(decision)
           }) do
      {:ok, onboarding}
    end
  end

  defp ensure_needs_review(%{status: :needs_review}), do: :ok
  defp ensure_needs_review(_onboarding), do: {:error, :not_awaiting_review}
end
