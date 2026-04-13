defmodule Dust.Page do
  @moduledoc "A page of results from `Dust.enum/3` or `Dust.range/4`."

  @type item :: term()
  @type t :: %__MODULE__{items: [item()], next_cursor: String.t() | nil}

  defstruct items: [], next_cursor: nil

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      items: Keyword.get(opts, :items, []),
      next_cursor: Keyword.get(opts, :next_cursor)
    }
  end

  defimpl Enumerable do
    def count(page), do: {:ok, length(page.items)}
    def member?(page, value), do: {:ok, Enum.member?(page.items, value)}
    def reduce(page, acc, fun), do: Enumerable.List.reduce(page.items, acc, fun)
    def slice(page), do: {:ok, length(page.items), &Enumerable.List.slice(page.items, &1, &2, length(page.items))}
  end
end
