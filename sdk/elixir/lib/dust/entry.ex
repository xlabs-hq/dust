defmodule Dust.Entry do
  @moduledoc "A single cached entry with metadata."

  @type t :: %__MODULE__{
          path: String.t(),
          value: term(),
          type: String.t(),
          revision: integer()
        }

  defstruct [:path, :value, :type, :revision]

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      path: Keyword.fetch!(opts, :path),
      value: Keyword.fetch!(opts, :value),
      type: Keyword.fetch!(opts, :type),
      revision: Keyword.fetch!(opts, :revision)
    }
  end
end
