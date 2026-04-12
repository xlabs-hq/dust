defmodule DustWeb.WorkOSAuthController do
  use DustWeb, :controller

  require Logger

  alias Dust.Accounts

  defp redirect_uri(conn) do
    url(conn, ~p"/auth/callback")
  end

  # --- Page renders ---

  def login(conn, _params) do
    if conn.assigns[:current_scope] && conn.assigns.current_scope.user do
      redirect_to_org(conn, conn.assigns.current_scope.user)
    else
      render_inertia(conn, "Auth/Login", %{dev_bypass: dev_bypass?()})
    end
  end

  def register(conn, _params) do
    render_inertia(conn, "Auth/Register")
  end

  def forgot_password(conn, _params) do
    render_inertia(conn, "Auth/ForgotPassword")
  end

  def reset_password_page(conn, %{"token" => token}) do
    render_inertia(conn, "Auth/ResetPassword", %{token: token})
  end

  def reset_password_page(conn, _params) do
    conn
    |> put_flash(:error, "Invalid password reset link.")
    |> redirect(to: ~p"/auth/forgot-password")
  end

  # --- Embedded auth actions ---

  @doc """
  Check if an email requires SSO. If so, redirect to SSO.
  Otherwise return JSON {mode: "password"}.
  """
  def check_email(conn, %{"email" => email}) do
    with {:ok, %{data: [user | _]}} <-
           WorkOS.UserManagement.list_users(%{email: email}),
         org_id when is_binary(org_id) <- get_sso_org_id(user) do
      # User belongs to an SSO-enforced org — redirect to SSO
      case WorkOS.UserManagement.get_authorization_url(%{
             organization_id: org_id,
             redirect_uri: redirect_uri(conn),
             client_id: WorkOS.client_id()
           }) do
        {:ok, url} ->
          json(conn, %{mode: "sso", redirect_url: url})

        {:error, _} ->
          json(conn, %{mode: "password"})
      end
    else
      _ ->
        # No user found or no SSO org — proceed with password
        json(conn, %{mode: "password"})
    end
  end

  @doc """
  Authenticate with email and password.
  """
  def sign_in(conn, %{"email" => email, "password" => password}) do
    if dev_bypass?() do
      dev_login(conn)
    else
      case authenticate_with_password_raw(email, password, conn) do
        {:ok, workos_user} ->
          case find_or_create_user(workos_user) do
            {:ok, user} ->
              log_in_user(conn, user)

            {:error, reason} ->
              Logger.error("Account creation failed after password auth: #{inspect(reason)}")

              conn
              |> put_status(422)
              |> json(%{error: "Account creation failed. Please try again."})
          end

        {:error, :email_verification_required, pending_token} ->
          conn
          |> put_status(200)
          |> json(%{
            requires_verification: true,
            pending_authentication_token: pending_token,
            email: email
          })

        {:error, :sso_required} ->
          conn
          |> put_status(422)
          |> json(%{error: "Your organization requires SSO. Please use the SSO login."})

        {:error, message} when is_binary(message) ->
          conn
          |> put_status(401)
          |> json(%{error: message})
      end
    end
  end

  @doc """
  Create a new user with email and password, then log them in.
  """
  def sign_up(conn, %{"email" => email, "password" => password} = params) do
    user_attrs = %{
      email: email,
      password: password,
      first_name: params["first_name"],
      last_name: params["last_name"]
    }

    case WorkOS.UserManagement.create_user(user_attrs) do
      {:ok, workos_user} ->
        authenticate_and_login(conn, workos_user, email, password)

      {:error, %WorkOS.Error{code: "user_creation_error"} = error}
      when is_list(error.errors) ->
        # User already exists on WorkOS (e.g. previous attempt created user but
        # password validation failed). Look up the existing user, update their
        # password, and proceed normally.
        if Enum.any?(error.errors, &(&1["code"] == "email_not_available")) do
          case find_workos_user_by_email(email) do
            {:ok, workos_user} ->
              case WorkOS.UserManagement.update_user(workos_user.id, %{password: password}) do
                {:ok, workos_user} ->
                  authenticate_and_login(conn, workos_user, email, password)

                {:error, %WorkOS.Error{} = update_error} ->
                  conn
                  |> put_status(422)
                  |> json(%{error: format_workos_error(update_error)})
              end

            {:error, reason} ->
              Logger.error("WorkOS list_users failed during retry: #{inspect(reason)}")

              conn
              |> put_status(422)
              |> json(%{error: "Could not create account. Please try again."})
          end
        else
          conn
          |> put_status(422)
          |> json(%{error: format_workos_error(error)})
        end

      {:error, %WorkOS.Error{} = error} ->
        conn
        |> put_status(422)
        |> json(%{error: format_workos_error(error)})

      {:error, error} ->
        Logger.error("WorkOS create_user failed: #{inspect(error)}")

        conn
        |> put_status(422)
        |> json(%{error: "Could not create account. Please try again."})
    end
  end

  @doc """
  Complete email verification and authenticate.
  Uses authenticate_with_email_verification with the pending token + code.
  """
  def verify_email(conn, %{"pending_authentication_token" => pending_token, "code" => code}) do
    case authenticate_with_email_verification_raw(pending_token, code, conn) do
      {:ok, workos_user} ->
        case find_or_create_user(workos_user) do
          {:ok, user} ->
            log_in_user(conn, user)

          {:error, _} ->
            conn
            |> put_status(422)
            |> json(%{error: "Verification succeeded. Please sign in."})
        end

      {:error, message} ->
        conn
        |> put_status(422)
        |> json(%{error: message})
    end
  end

  @doc """
  Resend the email verification code.
  """
  def resend_verification(conn, %{"user_id" => user_id}) do
    _ = WorkOS.UserManagement.send_verification_email(user_id)
    json(conn, %{sent: true})
  end

  @doc """
  Send a password reset email. Always returns success to avoid leaking accounts.
  """
  def send_reset_email(conn, %{"email" => email}) do
    reset_url = url(conn, ~p"/auth/reset-password")

    # Always return success to avoid leaking whether an account exists
    _ =
      WorkOS.UserManagement.send_password_reset_email(%{
        email: email,
        password_reset_url: reset_url
      })

    json(conn, %{sent: true})
  end

  @doc """
  Reset password with token from email link.
  """
  def do_reset_password(conn, %{"token" => token, "new_password" => new_password}) do
    case WorkOS.UserManagement.reset_password(%{
           token: token,
           new_password: new_password
         }) do
      {:ok, _} ->
        json(conn, %{success: true})

      {:error, %WorkOS.Error{} = error} ->
        conn
        |> put_status(422)
        |> json(%{error: format_workos_error(error)})

      {:error, error} ->
        Logger.error("Password reset failed: #{inspect(error)}")

        conn
        |> put_status(422)
        |> json(%{error: "Could not reset password. The link may have expired."})
    end
  end

  # --- Existing SSO/callback flow ---

  @doc """
  Redirect to WorkOS AuthKit hosted login (SSO fallback).
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
            log_in_user(conn, user)

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

  # --- Private helpers ---

  defp authenticate_and_login(conn, workos_user, email, password) do
    case authenticate_with_password_raw(email, password, conn) do
      {:ok, _} ->
        case find_or_create_user(workos_user) do
          {:ok, user} -> log_in_user(conn, user)
          {:error, _} -> fallback_login(conn, workos_user)
        end

      {:error, :email_verification_required, pending_token} ->
        conn
        |> put_status(200)
        |> json(%{
          requires_verification: true,
          pending_authentication_token: pending_token,
          email: email
        })

      {:error, _} ->
        # Auth failed for another reason — still create local user and log in
        fallback_login(conn, workos_user)
    end
  end

  defp find_workos_user_by_email(email) do
    case WorkOS.UserManagement.list_users(%{email: email, limit: 1}) do
      {:ok, %{data: [workos_user | _]}} -> {:ok, workos_user}
      {:ok, %{data: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

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

  # Handle WorkOS structs (returned by create_user)
  defp find_or_create_user(%{id: workos_id, email: email} = workos_user) do
    find_or_create_user(%{
      "id" => workos_id,
      "email" => email,
      "first_name" => Map.get(workos_user, :first_name),
      "last_name" => Map.get(workos_user, :last_name)
    })
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

  defp get_sso_org_id(%{organization_memberships: memberships})
       when is_list(memberships) and memberships != [] do
    # If user has org memberships, check if any require SSO
    # For now, return the first org ID (can be refined later)
    case List.first(memberships) do
      %{organization_id: org_id} -> org_id
      _ -> nil
    end
  end

  defp get_sso_org_id(_), do: nil

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

    log_in_user(conn, user)
  end

  defp fallback_login(conn, workos_user) do
    case find_or_create_user(workos_user) do
      {:ok, user} ->
        log_in_user(conn, user)

      {:error, _} ->
        conn
        |> put_status(422)
        |> json(%{error: "Account created but login failed. Try signing in."})
    end
  end

  defp log_in_user(conn, user) do
    token = Accounts.generate_user_session_token(user)
    user_return_to = get_session(conn, :user_return_to)
    redirect_to = user_return_to || signed_in_path(user)

    conn =
      conn
      |> configure_session(renew: true)
      |> clear_session()
      |> put_session(:user_token, token)
      |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")

    # JSON requests (from fetch-based auth forms) get a redirect URL;
    # HTML requests (from SSO callback) get a server-side redirect.
    if json_request?(conn) do
      json(conn, %{redirect_to: redirect_to})
    else
      redirect(conn, to: redirect_to)
    end
  end

  defp json_request?(conn) do
    case get_req_header(conn, "accept") do
      [accept | _] -> String.contains?(accept, "application/json")
      _ -> false
    end
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

  # Raw email verification authenticate call. The WorkOS SDK sends the field as
  # `pending_authentication_code`, but the API expects `pending_authentication_token`.
  defp authenticate_with_email_verification_raw(pending_token, code, conn) do
    client = WorkOS.client()

    body = %{
      client_id: WorkOS.client_id(client),
      client_secret: WorkOS.api_key(client),
      grant_type: "urn:workos:oauth:grant-type:email-verification:code",
      code: code,
      pending_authentication_token: pending_token,
      ip_address: get_peer_ip(conn),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    }

    case Req.post("#{client.base_url}/user_management/authenticate",
           json: body,
           headers: [{"authorization", "Bearer #{WorkOS.api_key(client)}"}]
         ) do
      {:ok, %{status: status, body: %{"user" => user}}} when status in 200..299 ->
        {:ok, user}

      {:ok, %{body: %{"errors" => [%{"message" => msg} | _]}}} ->
        {:error, msg}

      {:ok, %{body: %{"message" => message}}} ->
        {:error, message}

      {:error, _} ->
        {:error, "Invalid or expired code. Please try again."}
    end
  end

  # Make a raw authenticate_with_password call that preserves the
  # pending_authentication_token from email_verification_required errors.
  # The WorkOS SDK's Error struct drops this field.
  defp authenticate_with_password_raw(email, password, conn) do
    client = WorkOS.client()

    body = %{
      client_id: WorkOS.client_id(client),
      client_secret: WorkOS.api_key(client),
      grant_type: "password",
      email: email,
      password: password,
      ip_address: get_peer_ip(conn),
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    }

    case Req.post("#{client.base_url}/user_management/authenticate",
           json: body,
           headers: [{"authorization", "Bearer #{WorkOS.api_key(client)}"}]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body["user"]}

      {:ok,
       %{
         body: %{"code" => "email_verification_required", "pending_authentication_token" => token}
       }} ->
        {:error, :email_verification_required, token}

      {:ok, %{body: %{"code" => "sso_required"}}} ->
        {:error, :sso_required}

      {:ok, %{body: %{"message" => message}}} ->
        {:error, message}

      {:error, _} ->
        {:error, "Authentication failed. Please try again."}
    end
  end

  defp format_workos_error(%WorkOS.Error{message: message, errors: errors})
       when is_list(errors) and errors != [] do
    details =
      errors
      |> Enum.map(fn
        %{"message" => msg} -> String.trim(msg)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    case details do
      [] -> message
      msgs -> Enum.join(msgs, " ")
    end
  end

  defp format_workos_error(%WorkOS.Error{message: message}) when is_binary(message), do: message
  defp format_workos_error(_), do: "Something went wrong. Please try again."
end
