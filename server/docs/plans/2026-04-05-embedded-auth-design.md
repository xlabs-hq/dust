# Embedded Auth: WorkOS Password + SSO Fallback

Replace the redirect-based AuthKit login with an embedded email/password form.
SSO-required users redirect automatically; everyone else stays in-app.

## Routes

```
GET  /auth/login            → render Login page (existing)
GET  /auth/register         → render Register page (new)
GET  /auth/forgot-password  → render ForgotPassword page (new)
GET  /auth/reset-password   → render ResetPassword page (new)
POST /auth/check-email      → check if SSO required; return mode or redirect
POST /auth/sign-in          → authenticate_with_password, create session
POST /auth/sign-up          → create_user + auto-login
POST /auth/forgot-password  → send_password_reset_email
POST /auth/reset-password   → reset_password with token
GET  /auth/callback         → handle SSO redirect return (existing, unchanged)
DELETE /auth/logout          → clear session (existing, unchanged)
```

## Controller: WorkOSAuthController

### check_email(conn, %{"email" => email})

1. Call `WorkOS.UserManagement.list_users(email: email)`
2. If user found and belongs to an org with SSO enforced:
   - Redirect to `get_authorization_url` with `organization_id`
3. Otherwise return JSON `%{mode: "password"}`

### sign_in(conn, %{"email" => email, "password" => password})

1. Call `WorkOS.UserManagement.authenticate_with_password(%{email, password, ip_address, user_agent})`
2. On success: `find_or_create_user` then `log_in_user` (existing helpers)
3. On error: re-render Login with inline error via Inertia

### sign_up(conn, %{"email", "password", "first_name", "last_name"})

1. Call `WorkOS.UserManagement.create_user(%{email, password, first_name, last_name})`
2. On success: call `authenticate_with_password` to get tokens, then `find_or_create_user` + `log_in_user`
3. On error: re-render Register with validation errors

### forgot_password(conn, %{"email" => email})

1. Call `WorkOS.UserManagement.send_password_reset_email(%{email, password_reset_url})`
2. Always show "Check your email" (don't leak whether account exists)

### do_reset_password(conn, %{"token" => token, "new_password" => password})

1. Call `WorkOS.UserManagement.reset_password(%{token, new_password})`
2. On success: redirect to login with flash
3. On error: re-render with error

## React Pages

### Auth/Login.tsx (replace existing)

Two-step form, single component with state:

- Step 1: email input + "Continue" button + "Create account" link
- Step 2: password input + "Sign in" button + "Forgot password?" link + back arrow

Step 1 POSTs to `/auth/check-email`. If response is `{mode: "password"}`, transition to step 2 client-side. If SSO, Inertia handles the redirect.

Step 2 POSTs to `/auth/sign-in`. Errors shown inline.

Full-screen layout (no Shell). Matches current centered design.

### Auth/Register.tsx (new)

Form fields: first name, last name, email, password.
POSTs to `/auth/sign-up`.
Full-screen layout. Link back to login.

### Auth/ForgotPassword.tsx (new)

Email input. POSTs to `/auth/forgot-password`.
Shows confirmation message on submit.
Full-screen layout. Link back to login.

### Auth/ResetPassword.tsx (new)

Reads token from URL query params.
New password + confirm password fields.
POSTs to `/auth/reset-password`.
Full-screen layout. Redirects to login on success.

## Dev Bypass

When `dev_bypass_auth` is true, the Login page shows a "Dev Login" button
that links to `/auth/authorize` (existing dev_login flow).

## Error Handling

- Wrong password: inline "Invalid email or password"
- Account locked: inline message
- Email not verified: if WorkOS returns pending_authentication_token, show verification code input (future enhancement, not in v1)
- SSO required: automatic redirect, no error shown
- Network errors: generic "Something went wrong" toast

## What Stays Unchanged

- `callback/2` action (SSO return)
- `logout/2` action
- `log_in_user/2` private function
- `find_or_create_user/1` private function
- `create_user_with_org/1` private function
- Auth plug pipeline
- Session management
