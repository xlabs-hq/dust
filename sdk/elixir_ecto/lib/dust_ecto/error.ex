defmodule DustEcto.Error do
  @moduledoc """
  Single error struct returned from `DustEcto.Repo` when transport
  failures or server errors occur. Validation errors return
  `{:error, %Ecto.Changeset{}}` instead — that path is unchanged.

  ## Kinds

    * `:network` — Req call failed before reaching the server (connection
      refused, DNS, TLS, etc.). `retryable?` is `true`.
    * `:http` — server replied with a non-2xx, non-recognized status.
      `detail` carries the status + body. Usually retryable on 5xx,
      not on 4xx.
    * `:conflict` — `If-Match` precondition failed. `detail` carries
      `current_revision` and (for batch_write) `op_index` + `path`.
    * `:not_supported` — feature unavailable on the active transport
      (e.g. `subscribe` in HTTP mode). Not retryable.
    * `:nothing_to_write` — `Repo.insert`/`update` had no fields to
      send. Not retryable; usually a bug in the caller's changeset.
    * `:timeout` — sync write didn't get an ack within the configured
      window. The write may still eventually succeed; do not retry
      blindly.
    * `:unauthorized` — token rejected by the server.
    * `:invalid_params` — server rejected the request shape.
    * `:rate_limited` — server returned 429. `detail` may include
      `Retry-After`.
  """

  @type kind ::
          :network
          | :http
          | :conflict
          | :not_supported
          | :nothing_to_write
          | :timeout
          | :unauthorized
          | :invalid_params
          | :rate_limited

  @type t :: %__MODULE__{
          kind: kind(),
          detail: term(),
          retryable?: boolean()
        }

  defstruct [:kind, :detail, retryable?: false]

  @doc "Construct an error of the given kind."
  @spec new(kind(), term(), keyword()) :: t()
  def new(kind, detail \\ nil, opts \\ []) do
    %__MODULE__{
      kind: kind,
      detail: detail,
      retryable?: Keyword.get(opts, :retryable?, default_retryable?(kind))
    }
  end

  defp default_retryable?(:network), do: true
  defp default_retryable?(:rate_limited), do: true
  defp default_retryable?(:timeout), do: false
  defp default_retryable?(_), do: false
end
