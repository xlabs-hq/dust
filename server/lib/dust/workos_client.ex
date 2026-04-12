defmodule Dust.WorkOSClient do
  @moduledoc """
  Indirection for WorkOS API calls so tests can stub them. The default
  implementation delegates to the real `WorkOS.UserManagement` library.
  """

  @callback authenticate_with_code(map()) ::
              {:ok, %{user: WorkOS.UserManagement.User.t()}} | {:error, term()}

  def impl, do: Application.get_env(:dust, :workos_client, __MODULE__.Default)

  def authenticate_with_code(params), do: impl().authenticate_with_code(params)
end

defmodule Dust.WorkOSClient.Default do
  @behaviour Dust.WorkOSClient

  @impl true
  def authenticate_with_code(params) do
    WorkOS.UserManagement.authenticate_with_code(params)
  end
end
