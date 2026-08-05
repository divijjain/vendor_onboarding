defmodule VendorOnboarding.AgentService do
  @moduledoc """
  The only module that makes HTTP calls to the Python/FastAPI agent service.
  Built on `Req`. This is the one place rescue/timeout handling belongs —
  action modules never rescue for expected failures, but a real external
  call can fail in ways worth catching here.
  """

  @spec trigger(map()) :: {:ok, map()} | {:error, term()}
  def trigger(%{onboarding_id: _, document_paths: _} = payload) do
    req_options()
    |> Req.new()
    |> Req.post(url: "/trigger", json: payload)
    |> handle_response()
  rescue
    exception -> {:error, exception}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, {:unexpected_status, status, body}}
  end

  defp handle_response({:error, reason}), do: {:error, reason}

  defp req_options do
    Application.fetch_env!(:vendor_onboarding, __MODULE__)
    |> Keyword.take([:base_url, :plug])
  end
end
