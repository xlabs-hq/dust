defmodule Dust.Protocol.Glob do
  @moduledoc """
  Segment-aware glob matching against `Dust.Protocol.Path` segment
  lists.

  Mirrors `DustProtocol.Glob` from the canonical wire-protocol
  package.

  ## Pattern grammar

  A pattern is a non-empty list of pattern segments. Each segment is
  either:

    * `"*"` — matches exactly one path segment
    * `"**"` — matches one or more path segments; **only valid in the
      tail position**
    * `"\\*"` — matches a path segment that is literally `"*"`
    * `"\\**"` — matches a path segment that is literally `"**"`
    * any other string — matches that exact path segment

  Patterns can also be given as rendered slash strings, decoded with
  the same JSON Pointer escape rules as `Dust.Protocol.Path`.
  """

  # Shadow the imported Kernel.match?/2 macro — we define a function
  # with the same name.
  import Kernel, except: [match?: 2]

  alias Dust.Protocol.Path

  @type pattern_input :: String.t() | [String.t(), ...]
  @type compiled :: {:compiled, [token]}
  @type token :: {:literal, String.t()} | :wildcard_one | :wildcard_many

  @type error ::
          :empty_path
          | :empty_segment
          | :invalid_escape
          | :not_a_string
          | :not_a_list
          | :wildcard_many_not_tail

  @spec compile(pattern_input()) :: {:ok, compiled()} | {:error, error()}
  def compile(pattern) when is_binary(pattern) do
    with {:ok, segments} <- Path.parse_rendered(pattern) do
      compile_segments(segments)
    end
  end

  def compile(pattern) when is_list(pattern) do
    with {:ok, segments} <- Path.from_segments(pattern) do
      compile_segments(segments)
    end
  end

  def compile(_), do: {:error, :not_a_string}

  @spec compile!(pattern_input()) :: compiled()
  def compile!(pattern) do
    case compile(pattern) do
      {:ok, c} -> c
      {:error, reason} -> raise ArgumentError, "invalid glob pattern: #{inspect(reason)}"
    end
  end

  defp compile_segments(segments) do
    tokens = Enum.map(segments, &classify_segment/1)

    case validate_tokens(tokens) do
      :ok -> {:ok, {:compiled, tokens}}
      err -> err
    end
  end

  defp classify_segment("*"), do: :wildcard_one
  defp classify_segment("**"), do: :wildcard_many
  defp classify_segment("\\*"), do: {:literal, "*"}
  defp classify_segment("\\**"), do: {:literal, "**"}
  defp classify_segment(other), do: {:literal, other}

  defp validate_tokens(tokens) do
    case Enum.find_index(tokens, &(&1 == :wildcard_many)) do
      nil -> :ok
      idx when idx == length(tokens) - 1 -> :ok
      _ -> {:error, :wildcard_many_not_tail}
    end
  end

  @spec match?(compiled() | pattern_input(), [String.t()]) :: boolean()
  def match?({:compiled, tokens}, path) when is_list(path) do
    do_match(tokens, path)
  end

  def match?(pattern, path) when is_list(path) do
    match?(compile!(pattern), path)
  end

  defp do_match([], []), do: true
  defp do_match([], _path), do: false
  defp do_match([:wildcard_many], path), do: path != []
  defp do_match(_tokens, []), do: false

  defp do_match([:wildcard_one | t_rest], [_ | p_rest]),
    do: do_match(t_rest, p_rest)

  defp do_match([{:literal, lit} | t_rest], [lit | p_rest]),
    do: do_match(t_rest, p_rest)

  defp do_match(_, _), do: false
end
