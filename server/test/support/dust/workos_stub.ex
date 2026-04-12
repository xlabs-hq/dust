defmodule Dust.WorkOSStub do
  @behaviour Dust.WorkOSClient

  def set_response(response) do
    Process.put({__MODULE__, :response}, response)
  end

  @impl true
  def authenticate_with_code(_params) do
    case Process.get({__MODULE__, :response}) do
      nil -> {:error, :no_stub_set}
      {:error, _} = err -> err
      response -> {:ok, response}
    end
  end
end
