defmodule Dust.Protocol.Path do
  @moduledoc """
  Segment-first paths for the Dust Elixir SDK.

  A path is an ordered, non-empty list of non-empty string segments:

      ["posts", "hello.world", "image/file"]

  Public SDK functions accept either a segment list or a canonical
  rendered slash string (see `from_input/1`). Internally the SDK uses
  segment lists; strings are rendered at boundaries (cache keys, wire
  protocol, log lines).

  This module mirrors `DustProtocol.Path` from the canonical wire-
  protocol package; the SDK keeps its own copy so it can be Hex-
  publishable without taking a dep on the protocol package.

  ## Rendering

  Canonical rendered paths join segments with `/` and escape per RFC
  6901 (JSON Pointer) inside each segment:

      `~` -> `~0`
      `/` -> `~1`

  No other character has any special meaning. In particular, `.` is
  literal — `"example.com"` is one segment, not two.

  ## Migration note

  This module replaces the legacy dot-as-separator API that shipped
  in earlier capability versions. `Dust.Protocol.Path.LegacyDot` is
  available as a transitional helper for code that still consumes
  dotted-string paths from old data; it is deleted at the end of the
  migration.
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

  @spec from_segments!(term()) :: segments()
  def from_segments!(segments) do
    case from_segments(segments) do
      {:ok, segs} -> segs
      {:error, reason} -> raise ArgumentError, "invalid segments: #{inspect(reason)}"
    end
  end

  # ----------------------------------------------------------------------
  # Rendering
  # ----------------------------------------------------------------------

  @spec render(term()) :: {:ok, rendered()} | {:error, error()}
  def render(segments) do
    case from_segments(segments) do
      {:ok, segs} -> {:ok, segs |> Enum.map(&escape_segment/1) |> Enum.join("/")}
      err -> err
    end
  end

  @spec render!(term()) :: rendered()
  def render!(segments) do
    case render(segments) do
      {:ok, str} -> str
      {:error, reason} -> raise ArgumentError, "cannot render: #{inspect(reason)}"
    end
  end

  # `~` must be escaped first or the `/` -> `~1` substitution would
  # create false `~1` sequences in subsequent decoding.
  defp escape_segment(seg) do
    seg
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  # ----------------------------------------------------------------------
  # Parsing
  # ----------------------------------------------------------------------

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

  defp unescape_segment(seg), do: do_unescape(seg, [])

  defp do_unescape("", acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp do_unescape("~0" <> rest, acc), do: do_unescape(rest, ["~" | acc])
  defp do_unescape("~1" <> rest, acc), do: do_unescape(rest, ["/" | acc])
  defp do_unescape("~" <> _rest, _acc), do: {:error, :invalid_escape}

  defp do_unescape(<<ch::utf8, rest::binary>>, acc),
    do: do_unescape(rest, [<<ch::utf8>> | acc])

  # ----------------------------------------------------------------------
  # Normalize
  # ----------------------------------------------------------------------

  @spec normalize_rendered(term()) :: {:ok, rendered()} | {:error, error()}
  def normalize_rendered(s) do
    with {:ok, segs} <- parse_rendered(s) do
      render(segs)
    end
  end

  # ----------------------------------------------------------------------
  # Boundary input (SDK ergonomics: accept string or list)
  # ----------------------------------------------------------------------

  @doc """
  Accept either a rendered slash string or a segment list, return
  validated segments. SDK entry points use this so callers can write
  `Dust.put(store, "a/b/c", val)` or `Dust.put(store, ["a","b","c"], val)`
  interchangeably.
  """
  @spec from_input(term()) :: {:ok, segments()} | {:error, error()}
  def from_input(s) when is_binary(s), do: parse_rendered(s)
  def from_input(segs) when is_list(segs), do: from_segments(segs)
  def from_input(_), do: {:error, :not_a_string}

  # ----------------------------------------------------------------------
  # Composition
  # ----------------------------------------------------------------------

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

  @spec concat(term(), term()) :: {:ok, segments()} | {:error, error()}
  def concat(parent, tail) do
    with {:ok, parent_segs} <- from_segments(parent),
         {:ok, tail_segs} <- from_segments(tail) do
      {:ok, parent_segs ++ tail_segs}
    end
  end

  @spec ancestor?(segments(), segments()) :: boolean()
  def ancestor?(ancestor, descendant) when is_list(ancestor) and is_list(descendant) do
    length(ancestor) < length(descendant) and
      Enum.zip(ancestor, descendant) |> Enum.all?(fn {a, b} -> a == b end)
  end

  @spec related?(segments(), segments()) :: boolean()
  def related?(a, b) when is_list(a) and is_list(b) do
    a == b or ancestor?(a, b) or ancestor?(b, a)
  end

  @spec render_descendant_prefix(term()) :: {:ok, rendered()} | {:error, error()}
  def render_descendant_prefix(segments) do
    case render(segments) do
      {:ok, str} -> {:ok, str <> "/"}
      err -> err
    end
  end

  @spec render_descendant_prefix!(term()) :: rendered()
  def render_descendant_prefix!(segments) do
    case render_descendant_prefix(segments) do
      {:ok, str} -> str
      {:error, reason} -> raise ArgumentError, "cannot render prefix: #{inspect(reason)}"
    end
  end
end
