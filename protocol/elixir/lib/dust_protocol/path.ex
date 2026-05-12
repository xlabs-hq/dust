defmodule DustProtocol.Path do
  @moduledoc """
  Segment-first paths.

  A path is an ordered, non-empty list of non-empty string segments:

      ["posts", "hello.world", "image/file"]

  Segments are the **authoritative** form. Strings are a **rendering**
  used at boundaries (URLs, SQLite keys, CLI args, logs, exports).

  ## Rendering

  Canonical rendered paths join segments with `/` and escape per RFC
  6901 (JSON Pointer) inside each segment:

      `~` -> `~0`
      `/` -> `~1`

  No other character has any special meaning. In particular, `.` is
  literal — `"example.com"` is one segment, not two.

  Examples:

      segments              rendered
      ["posts", "hello"]    posts/hello
      ["hello.world"]       hello.world
      ["image/file"]        image~1file
      ["a~b"]               a~0b
      ["a/b~c"]             a~1b~0c

  ## What's invalid

  - empty path
  - empty segment (rendered: leading `/`, trailing `/`, consecutive `//`)
  - bare `~` (must be `~0` or `~1`)
  - any `~N` for N other than 0 or 1

  ## Migration note

  This module replaces the dot-as-separator model that shipped in
  earlier capability versions. The legacy form lives at
  `DustProtocol.Path.LegacyDot` and is only used by the one-shot
  migration tool.
  """

  @type segment :: String.t()
  @type segments :: [segment, ...]

  @type rendered :: String.t()

  @type error ::
          :empty_path
          | :empty_segment
          | :invalid_escape
          | :not_a_string
          | :not_a_list

  # ----------------------------------------------------------------------
  # Validation
  # ----------------------------------------------------------------------

  @doc """
  Validates a segment list.

  Returns `{:ok, segments}` if every segment is a non-empty binary,
  `{:error, reason}` otherwise.
  """
  @spec from_segments(term()) :: {:ok, segments()} | {:error, error()}
  def from_segments([]), do: {:error, :empty_path}

  def from_segments(segments) when is_list(segments) do
    cond do
      not Enum.all?(segments, &is_binary/1) -> {:error, :not_a_string}
      Enum.any?(segments, &(&1 == "")) -> {:error, :empty_segment}
      true -> {:ok, segments}
    end
  end

  def from_segments(_), do: {:error, :not_a_list}

  @doc "Like `from_segments/1` but raises on invalid input."
  @spec from_segments!(term()) :: segments()
  def from_segments!(segments) do
    case from_segments(segments) do
      {:ok, segs} -> segs
      {:error, reason} -> raise ArgumentError, "invalid segments: #{inspect(reason)}"
    end
  end

  # ----------------------------------------------------------------------
  # Rendering: segments -> rendered string
  # ----------------------------------------------------------------------

  @doc """
  Render a segment list to canonical slash form, escaping `~` and `/`
  inside each segment per RFC 6901.
  """
  @spec render(term()) :: {:ok, rendered()} | {:error, error()}
  def render(segments) do
    case from_segments(segments) do
      {:ok, segs} -> {:ok, segs |> Enum.map(&escape_segment/1) |> Enum.join("/")}
      err -> err
    end
  end

  @doc "Like `render/1` but raises on invalid input."
  @spec render!(term()) :: rendered()
  def render!(segments) do
    case render(segments) do
      {:ok, str} -> str
      {:error, reason} -> raise ArgumentError, "cannot render: #{inspect(reason)}"
    end
  end

  # Escape order matters — `~` must be escaped first or the `/` -> `~1`
  # substitution would create false `~1` sequences in subsequent decoding.
  defp escape_segment(seg) do
    seg
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  # ----------------------------------------------------------------------
  # Parsing: rendered string -> segments
  # ----------------------------------------------------------------------

  @doc """
  Parse a canonical rendered path into segments. Rejects empty paths,
  empty segments (leading/trailing/double slash), and invalid `~`
  escapes.
  """
  @spec parse_rendered(term()) :: {:ok, segments()} | {:error, error()}
  def parse_rendered(""), do: {:error, :empty_path}
  def parse_rendered(s) when not is_binary(s), do: {:error, :not_a_string}

  def parse_rendered(s) when is_binary(s) do
    segments = :binary.split(s, "/", [:global])

    if Enum.any?(segments, &(&1 == "")) do
      {:error, :empty_segment}
    else
      decode_all(segments, [])
    end
  end

  defp decode_all([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_all([seg | rest], acc) do
    case unescape_segment(seg) do
      {:ok, decoded} -> decode_all(rest, [decoded | acc])
      err -> err
    end
  end

  # Walks the segment once, treating `~` as the start of a two-char
  # escape. Anything else after `~` is `:invalid_escape`. This is
  # stricter than a `String.replace` pair: it actually rejects bad
  # input rather than silently leaving it.
  defp unescape_segment(seg) do
    do_unescape(seg, [])
  end

  defp do_unescape("", acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp do_unescape("~0" <> rest, acc), do: do_unescape(rest, ["~" | acc])
  defp do_unescape("~1" <> rest, acc), do: do_unescape(rest, ["/" | acc])
  defp do_unescape("~" <> _rest, _acc), do: {:error, :invalid_escape}

  defp do_unescape(<<ch::utf8, rest::binary>>, acc),
    do: do_unescape(rest, [<<ch::utf8>> | acc])

  # ----------------------------------------------------------------------
  # Normalize: rendered -> rendered (validates + re-emits canonical)
  # ----------------------------------------------------------------------

  @doc """
  Round-trip a rendered path through parse + render. Useful at trust
  boundaries to canonicalise input (e.g. an HTTP request body).
  """
  @spec normalize_rendered(term()) :: {:ok, rendered()} | {:error, error()}
  def normalize_rendered(s) do
    with {:ok, segs} <- parse_rendered(s) do
      render(segs)
    end
  end

  # ----------------------------------------------------------------------
  # Boundary helpers: accept "either" shape (string or list)
  # ----------------------------------------------------------------------

  @doc """
  Accept either a rendered string or a segment list and return
  validated segments. SDK entry points use this to give callers the
  string-or-list ergonomics described in the README.
  """
  @spec from_input(term()) :: {:ok, segments()} | {:error, error()}
  def from_input(s) when is_binary(s), do: parse_rendered(s)
  def from_input(segs) when is_list(segs), do: from_segments(segs)
  def from_input(_), do: {:error, :not_a_string}

  # ----------------------------------------------------------------------
  # Composition
  # ----------------------------------------------------------------------

  @doc """
  Append a single segment to a path. The new segment is taken
  literally — no parsing, no special meaning for `.` or `/`.
  """
  @spec child(term(), term()) :: {:ok, segments()} | {:error, error()}
  def child(parent, segment) do
    with {:ok, parent_segs} <- from_segments(parent),
         :ok <- validate_single_segment(segment) do
      {:ok, parent_segs ++ [segment]}
    end
  end

  defp validate_single_segment(s) when is_binary(s) and s != "", do: :ok
  defp validate_single_segment(""), do: {:error, :empty_segment}
  defp validate_single_segment(_), do: {:error, :not_a_string}

  @doc """
  Append multiple segments. Equivalent to repeated `child/2` but
  cheaper for known-shape construction (e.g. dust_ecto's
  prefix+slug+field).
  """
  @spec concat(term(), term()) :: {:ok, segments()} | {:error, error()}
  def concat(parent, tail) do
    with {:ok, parent_segs} <- from_segments(parent),
         {:ok, tail_segs} <- from_segments(tail) do
      {:ok, parent_segs ++ tail_segs}
    end
  end

  @doc "True if `ancestor` is a strict ancestor of `descendant`."
  @spec ancestor?(segments(), segments()) :: boolean()
  def ancestor?(ancestor, descendant) when is_list(ancestor) and is_list(descendant) do
    length(ancestor) < length(descendant) and
      Enum.zip(ancestor, descendant) |> Enum.all?(fn {a, b} -> a == b end)
  end

  @doc """
  True when both arguments are valid paths AND either equal, or one
  is an ancestor of the other.
  """
  @spec related?(segments(), segments()) :: boolean()
  def related?(a, b) when is_list(a) and is_list(b) do
    a == b or ancestor?(a, b) or ancestor?(b, a)
  end

  @doc """
  Rendered prefix string suitable for SQL LIKE `<prefix>%` descendant
  matches. Always has a trailing `/` so it can't false-match a sibling
  whose rendered form shares the parent's prefix bytes.
  """
  @spec render_descendant_prefix(term()) :: {:ok, rendered()} | {:error, error()}
  def render_descendant_prefix(segments) do
    case render(segments) do
      {:ok, str} -> {:ok, str <> "/"}
      err -> err
    end
  end

  @doc "Like `render_descendant_prefix/1` but raises on invalid input."
  @spec render_descendant_prefix!(term()) :: rendered()
  def render_descendant_prefix!(segments) do
    case render_descendant_prefix(segments) do
      {:ok, str} -> str
      {:error, reason} -> raise ArgumentError, "cannot render prefix: #{inspect(reason)}"
    end
  end
end
