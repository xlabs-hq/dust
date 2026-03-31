defmodule Dust.FileRefTest do
  use ExUnit.Case

  alias Dust.FileRef

  test "from_map/2 creates a FileRef from a map" do
    map = %{
      "hash" => "sha256:abc123",
      "size" => 1024,
      "content_type" => "image/png",
      "filename" => "photo.png",
      "uploaded_at" => "2026-03-31T12:00:00Z"
    }

    ref = FileRef.from_map(map, server_url: "http://localhost:7000", token: "tok_123")

    assert %FileRef{} = ref
    assert ref.hash == "sha256:abc123"
    assert ref.size == 1024
    assert ref.content_type == "image/png"
    assert ref.filename == "photo.png"
    assert ref.uploaded_at == "2026-03-31T12:00:00Z"
    assert ref._server_url == "http://localhost:7000"
    assert ref._token == "tok_123"
  end

  test "from_map/1 works without opts" do
    map = %{
      "hash" => "sha256:def456",
      "size" => 512,
      "content_type" => "text/plain",
      "filename" => "readme.txt",
      "uploaded_at" => "2026-03-31T12:00:00Z"
    }

    ref = FileRef.from_map(map)

    assert ref.hash == "sha256:def456"
    assert ref._server_url == nil
    assert ref._token == nil
  end

  test "FileRef has the expected fields" do
    ref = %FileRef{}
    assert Map.has_key?(ref, :hash)
    assert Map.has_key?(ref, :size)
    assert Map.has_key?(ref, :content_type)
    assert Map.has_key?(ref, :filename)
    assert Map.has_key?(ref, :uploaded_at)
    assert Map.has_key?(ref, :_server_url)
    assert Map.has_key?(ref, :_token)
  end
end
