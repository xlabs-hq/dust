defmodule Dust.Protocol.CompatibilityTest do
  use ExUnit.Case, async: true

  @fixtures_path Path.expand("../../../../../protocol/spec/fixtures", __DIR__)

  describe "glob matching" do
    test "matches shared test vectors" do
      vectors = read_fixture("glob_vectors.json")

      for %{"pattern" => pattern, "path" => path, "match" => expected} <- vectors do
        result = Dust.Protocol.Glob.match?(pattern, path)
        assert result == expected,
          "Glob.match?(#{inspect(pattern)}, #{inspect(path)}) = #{result}, expected #{expected}"
      end
    end
  end

  describe "path parsing" do
    @describetag :pending_segment_migration

    # During segment-first migration the shared fixture file moved to
    # the new shape (`{segments, rendered, valid}`) while this SDK
    # still ships the legacy dotted `Dust.Protocol.Path` API. The two
    # are incompatible by design — the new fixture has cases like
    # `"hello.world" -> ["hello.world"]` (one segment) that the legacy
    # SDK can't represent. Re-enable once the SDK is on the new Path
    # API and we can call `parse_rendered/1` here. Tracked alongside
    # the rest of the segment-first work in
    # docs/plans/2026-05-12-segment-first-paths.md.
    @tag :skip
    test "matches shared test vectors" do
      vectors = read_fixture("path_vectors.json")

      for vector <- vectors do
        case vector do
          %{"input" => input, "valid" => true, "segments" => segments} ->
            assert {:ok, ^segments} = Dust.Protocol.Path.parse(input)

          %{"input" => input, "valid" => false, "error" => error} ->
            assert {:error, err} = Dust.Protocol.Path.parse(input)
            assert to_string(err) == error
        end
      end
    end
  end

  describe "codec roundtrip" do
    test "matches shared test vectors" do
      vectors = read_fixture("codec_vectors.json")

      for %{"format" => format, "input" => input, "roundtrip" => true} <- vectors do
        format_atom = String.to_existing_atom(format)
        {:ok, encoded} = Dust.Protocol.Codec.encode(format_atom, input)
        {:ok, decoded} = Dust.Protocol.Codec.decode(format_atom, encoded)
        assert decoded == input,
          "Codec roundtrip failed for #{format}: #{inspect(input)}"
      end
    end
  end

  defp read_fixture(name) do
    @fixtures_path
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end
end
