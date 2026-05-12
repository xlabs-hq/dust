defmodule DustProtocol.Glob do
  @moduledoc """
  Segment-aware glob matching against `DustProtocol.Path` segment
  lists.

  ## Pattern grammar

  A pattern is a non-empty list of pattern segments. Each segment is
  either:

    * the literal string `"*"` — matches exactly one path segment
    * the literal string `"**"` — matches one or more path segments;
      **only valid in the tail position**
    * the literal string `"\\*"` — matches a path segment that is
      literally `"*"`
    * the literal string `"\\**"` — matches a path segment that is
      literally `"**"`
    * any other string — matches that exact path segment

  Examples (pattern → matched path):

      ["posts", "*"]          ["posts", "hello"]
      ["posts", "**"]         ["posts", "a", "b", "c"]
      ["a", "\\*"]            ["a", "*"]
      ["files", "image.png"]  ["files", "image.png"]

  Patterns can also be given as rendered slash strings, decoded with
  the same JSON Pointer escape rules as `DustProtocol.Path`:

      "posts/*/title"
      "files/image~1png"
      "x/\\**"

  ## Invariants

    * Middle-position `**` is rejected at compile time. This is a
      deliberate restriction — supporting middle `**` (`a/**/z`) is
      possible but rarely useful and complicates the matcher. Plan
      docs/plans/2026-05-12-segment-first-paths.md picks
      tail-only.

    * Patterns inherit path segment validation: no empty segments,
      no bare `~`, etc.
  """

  # Defining `match?/2` shadows the `Kernel.match?/2` macro; tell the
  # compiler we know.
  import Kernel, except: [match?: 2]

  alias DustProtocol.Path

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

  # ----------------------------------------------------------------------
  # Compilation
  # ----------------------------------------------------------------------

  @doc """
  Compile a pattern (rendered string or segment list) into a form
  suitable for repeated matching.
  """
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

  @doc "Like `compile/1` but raises on invalid input."
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

  # Reject `**` anywhere except the final position. Walk once, looking
  # for a non-tail occurrence.
  defp validate_tokens(tokens) do
    case Enum.find_index(tokens, &(&1 == :wildcard_many)) do
      nil -> :ok
      idx when idx == length(tokens) - 1 -> :ok
      _ -> {:error, :wildcard_many_not_tail}
    end
  end

  # ----------------------------------------------------------------------
  # Matching
  # ----------------------------------------------------------------------

  @doc """
  Test whether `pattern` matches `path`.

  `pattern` may be a compiled pattern, a rendered string, or a
  segment list. `path` must be a segment list — use
  `DustProtocol.Path.parse_rendered/1` first if you have a string.

  Compile errors on raw-string/list patterns raise; pre-compile to
  surface them earlier.
  """
  @spec match?(compiled() | pattern_input(), [String.t()]) :: boolean()
  def match?({:compiled, tokens}, path) when is_list(path) do
    do_match(tokens, path)
  end

  def match?(pattern, path) when is_list(path) do
    match?(compile!(pattern), path)
  end

  # Walk pattern tokens vs path segments.
  #
  # `:wildcard_many` only appears in tail position (validated at
  # compile time), so we don't need the recursive-consume-or-skip
  # dance the old DustProtocol.Glob used. A single one-or-more guard
  # is enough.

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
