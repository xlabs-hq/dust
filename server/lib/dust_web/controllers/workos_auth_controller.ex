defmodule DustWeb.WorkOSAuthController do
  use DustWeb, :controller

  require Logger

  alias Dust.Accounts

  defp redirect_uri(conn) do
    url(conn, ~p"/auth/callback")
  end

  @doc """
  Redirect to WorkOS AuthKit hosted login.
  In dev mode without WorkOS credentials, auto-creates a dev user.
  """
  def authorize(conn, _params) do
    if dev_bypass?() do
      dev_login(conn)
    else
      case WorkOS.UserManagement.get_authorization_url(%{
             provider: "authkit",
             redirect_uri: redirect_uri(conn),
             client_id: WorkOS.client_id()
           }) do
        {:ok, authorization_url} ->
          redirect(conn, external: authorization_url)

        {:error, reason} ->
          Logger.error("WorkOS authorization URL error: #{inspect(reason)}")

          conn
          |> put_flash(:error, "Authentication error. Please try again.")
          |> redirect(to: ~p"/auth/login")
      end
    end
  end

  @doc """
  Handle the WorkOS OAuth callback. Exchange code for user info,
  find-or-create user, sync SSO org membership, create session.
  """
  def callback(conn, %{"code" => code}) do
    case WorkOS.UserManagement.authenticate_with_code(%{
           code: code,
           ip_address: get_peer_ip(conn),
           user_agent: get_req_header(conn, "user-agent") |> List.first()
         }) do
      {:ok, %{user: workos_user, organization_id: workos_org_id}} ->
        case find_or_create_user(workos_user) do
          {:ok, user} ->
            maybe_sync_sso_org(user, workos_org_id)

            conn
            |> log_in_user(user)

          {:error, reason} ->
            Logger.error("Account creation failed: #{inspect(reason)}")

            conn
            |> put_flash(:error, "Account creation failed. Please try again.")
            |> redirect(to: ~p"/auth/login")
        end

      {:error, reason} ->
        Logger.error("WorkOS authentication failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: ~p"/auth/login")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Authentication failed: missing authorization code.")
    |> redirect(to: ~p"/auth/login")
  end

  @doc """
  Render the login page via Inertia.
  """
  def login(conn, _params) do
    # If already logged in, redirect to home
    if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      redirect_to_org(conn, conn.assigns.current_scope.user)
    else
      render_inertia(conn, "Auth/Login")
    end
  end

  @doc """
  Clear session and redirect to login.
  """
  def logout(conn, _params) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_flash(:info, "Signed out successfully.")
    |> redirect(to: ~p"/auth/login")
  end

  # --- Private ---

  defp find_or_create_user(%{"id" => workos_id, "email" => email} = workos_user) do
    first_name = workos_user["first_name"]
    last_name = workos_user["last_name"]

    case Accounts.get_user_by_workos_id(workos_id) do
      %Accounts.User{} = user ->
        {:ok, user}

      nil ->
        case Accounts.get_user_by_email(email) do
          %Accounts.User{} = user ->
            Accounts.link_user_to_workos(user, workos_id)

          nil ->
            create_user_with_org(%{
              workos_id: workos_id,
              email: email,
              first_name: first_name,
              last_name: last_name
            })
        end
    end
  end

  defp create_user_with_org(attrs) do
    case Accounts.create_user(attrs) do
      {:ok, user} ->
        slug = email_to_slug(attrs.email)

        case Accounts.create_organization_with_owner(user, %{
               name: slug,
               slug: slug
             }) do
          {:ok, _org} -> {:ok, user}
          {:error, _} -> {:ok, user}
        end

      error ->
        error
    end
  end

  defp email_to_slug(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim_leading("-")
    |> String.trim_trailing("-")
    |> case do
      "" -> "user"
      slug -> slug
    end
  end

  defp maybe_sync_sso_org(_user, nil), do: :ok

  defp maybe_sync_sso_org(user, workos_org_id) when is_binary(workos_org_id) do
    case Accounts.get_organization_by_workos_id(workos_org_id) do
      nil -> :ok
      org -> Accounts.ensure_membership(user, org)
    end
  end

  defp dev_bypass? do
    Application.get_env(:dust, :dev_bypass_auth, false)
  end

  defp dev_login(conn) do
    user =
      case Accounts.get_user_by_email("dev@dust.local") do
        %Accounts.User{} = user ->
          user

        nil ->
          {:ok, user} =
            create_user_with_org(%{
              email: "dev@dust.local",
              first_name: "Dev",
              last_name: "User"
            })

          user
      end

    conn
    |> log_in_user(user)
  end

  defp log_in_user(conn, user) do
    token = Accounts.generate_user_session_token(user)
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
    |> redirect(to: user_return_to || signed_in_path(user))
  end

  defp signed_in_path(user) do
    orgs = Accounts.list_user_organizations(user)

    case orgs do
      [org | _] -> ~p"/#{org.slug}"
      [] -> ~p"/auth/login"
    end
  end

  defp redirect_to_org(conn, user) do
    redirect(conn, to: signed_in_path(user))
  end

  defp get_peer_ip(conn) do
    case Plug.Conn.get_peer_data(conn) do
      %{address: address} -> :inet.ntoa(address) |> to_string()
      _ -> nil
    end
  end
end
