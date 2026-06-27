defmodule Dust.Lease do
  @moduledoc """
  A held lease — a snapshot capability handle returned by `Dust.lease/3` and
  `Dust.renew/2`.

  Authority lives on the server: this struct is a point-in-time snapshot, not a
  live lock. `token` is the server-stamped fence token (monotonic, preserved
  across `renew`); pass the whole struct to `Dust.renew/2`, `Dust.release/1`,
  or a write's `fence:` option.
  """

  @type t :: %__MODULE__{
          key: String.t(),
          token: integer(),
          holder: String.t() | nil,
          expires_at: integer()
        }

  defstruct [:key, :token, :holder, :expires_at]

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      key: Keyword.fetch!(opts, :key),
      token: Keyword.fetch!(opts, :token),
      holder: Keyword.get(opts, :holder),
      expires_at: Keyword.fetch!(opts, :expires_at)
    }
  end
end
