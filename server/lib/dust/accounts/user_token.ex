defmodule Dust.Accounts.UserToken do
  use Dust.Schema
  import Ecto.Query

  @rand_size 32
  @session_validity_in_days 14

  schema "users_tokens" do
    field :token, :binary
    field :context, :string

    belongs_to :user, Dust.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Generates a session token. The raw token is stored in the session
  (signed cookie), while the actual binary is stored in the database.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %__MODULE__{token: token, context: "session", user_id: user.id}}
  end

  @doc """
  Returns a query that finds a valid session token and its associated user.
  """
  def verify_session_token_query(token) do
    query =
      from t in by_token_and_context_query(token, "session"),
        join: u in assoc(t, :user),
        where: t.inserted_at > ago(@session_validity_in_days, "day"),
        select: {u, t.inserted_at}

    {:ok, query}
  end

  @doc """
  Returns a query matching the given token and context.
  """
  def by_token_and_context_query(token, context) do
    from __MODULE__, where: [token: ^token, context: ^context]
  end

  @doc """
  Returns a query for all tokens belonging to a user in the given contexts.
  """
  def by_user_and_contexts_query(user, :all) do
    from t in __MODULE__, where: t.user_id == ^user.id
  end

  def by_user_and_contexts_query(user, [_ | _] = contexts) do
    from t in __MODULE__, where: t.user_id == ^user.id and t.context in ^contexts
  end
end
