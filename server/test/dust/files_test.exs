defmodule Dust.FilesTest do
  use Dust.DataCase, async: false

  alias Dust.Files

  setup do
    # Clean up test blobs directory before each test
    blob_dir = Files.blob_dir()
    File.rm_rf!(blob_dir)
    on_exit(fn -> File.rm_rf!(blob_dir) end)
    :ok
  end

  describe "upload/2" do
    test "uploads content and returns a file reference" do
      {:ok, ref} = Files.upload("hello world", filename: "hello.txt", content_type: "text/plain")

      assert ref["_type"] == "file"
      assert String.starts_with?(ref["hash"], "sha256:")
      assert ref["size"] == 11
      assert ref["content_type"] == "text/plain"
      assert ref["filename"] == "hello.txt"
      assert ref["uploaded_at"]
    end

    test "creates blob record in database" do
      {:ok, ref} = Files.upload("db test", filename: "test.txt")

      blob = Files.get_blob(ref["hash"])
      assert blob
      assert blob.hash == ref["hash"]
      assert blob.size == 7
      assert blob.reference_count == 1
    end

    test "content addressing: same content produces same hash" do
      {:ok, ref1} = Files.upload("identical content")
      {:ok, ref2} = Files.upload("identical content")

      assert ref1["hash"] == ref2["hash"]
    end

    test "content addressing: increments reference count on duplicate upload" do
      {:ok, ref} = Files.upload("counted content")
      Files.upload("counted content")

      blob = Files.get_blob(ref["hash"])
      assert blob.reference_count == 2
    end

    test "different content produces different hashes" do
      {:ok, ref1} = Files.upload("content A")
      {:ok, ref2} = Files.upload("content B")

      assert ref1["hash"] != ref2["hash"]
    end

    test "defaults content_type to application/octet-stream" do
      {:ok, ref} = Files.upload("binary data")

      assert ref["content_type"] == "application/octet-stream"
    end
  end

  describe "download/1" do
    test "downloads previously uploaded content" do
      {:ok, ref} = Files.upload("download me")

      assert {:ok, "download me"} = Files.download(ref["hash"])
    end

    test "returns error for nonexistent hash" do
      assert {:error, :not_found} =
               Files.download(
                 "sha256:0000000000000000000000000000000000000000000000000000000000000000"
               )
    end
  end

  describe "exists?/1" do
    test "returns true for uploaded blob" do
      {:ok, ref} = Files.upload("exists check")

      assert Files.exists?(ref["hash"])
    end

    test "returns false for nonexistent hash" do
      refute Files.exists?("sha256:nonexistent")
    end
  end

  describe "upload_from_path/2" do
    test "uploads a file from disk" do
      # Create a temp file
      tmp_path = Path.join(System.tmp_dir!(), "dust_test_upload.txt")
      File.write!(tmp_path, "file from disk")
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, ref} = Files.upload_from_path(tmp_path)

      assert ref["filename"] == "dust_test_upload.txt"
      assert ref["content_type"] == "text/plain"
      assert ref["size"] == 14
      assert {:ok, "file from disk"} = Files.download(ref["hash"])
    end

    test "detects common MIME types from extension" do
      for {ext, expected_mime} <- [
            {".jpg", "image/jpeg"},
            {".png", "image/png"},
            {".pdf", "application/pdf"},
            {".json", "application/json"}
          ] do
        tmp_path = Path.join(System.tmp_dir!(), "dust_test#{ext}")
        File.write!(tmp_path, "test content for #{ext}")
        on_exit(fn -> File.rm(tmp_path) end)

        {:ok, ref} = Files.upload_from_path(tmp_path)
        assert ref["content_type"] == expected_mime, "Expected #{expected_mime} for #{ext}"
      end
    end
  end

  describe "reference counting via Writer" do
    setup do
      {:ok, user} = Dust.Accounts.create_user(%{email: "fileref@example.com"})

      {:ok, org} =
        Dust.Accounts.create_organization_with_owner(user, %{name: "FileRef", slug: "fileref"})

      {:ok, store} = Dust.Stores.create_store(org, %{name: "files"})
      %{store: store}
    end

    test "overwriting a file path decrements old ref", %{store: store} do
      {:ok, ref1} = Files.upload("content A", filename: "a.txt")
      {:ok, ref2} = Files.upload("content B", filename: "b.txt")

      # Write first file ref
      Dust.Sync.write(store.id, %{
        op: :put_file,
        path: "doc",
        value: ref1,
        device_id: "d",
        client_op_id: "f1"
      })

      assert Files.get_blob(ref1["hash"]).reference_count == 1

      # Overwrite with second file ref — old ref should decrement
      Dust.Sync.write(store.id, %{
        op: :put_file,
        path: "doc",
        value: ref2,
        device_id: "d",
        client_op_id: "f2"
      })

      assert Files.get_blob(ref1["hash"]).reference_count == 0
      assert Files.get_blob(ref2["hash"]).reference_count == 1
    end

    test "deleting a file path decrements ref", %{store: store} do
      {:ok, ref} = Files.upload("delete me", filename: "d.txt")

      Dust.Sync.write(store.id, %{
        op: :put_file,
        path: "doc",
        value: ref,
        device_id: "d",
        client_op_id: "f1"
      })

      assert Files.get_blob(ref["hash"]).reference_count == 1

      Dust.Sync.write(store.id, %{
        op: :delete,
        path: "doc",
        value: nil,
        device_id: "d",
        client_op_id: "f2"
      })

      assert Files.get_blob(ref["hash"]).reference_count == 0
    end

    test "set on ancestor path decrements file refs in subtree", %{store: store} do
      {:ok, ref} = Files.upload("subtree file", filename: "s.txt")

      Dust.Sync.write(store.id, %{
        op: :put_file,
        path: "docs.readme",
        value: ref,
        device_id: "d",
        client_op_id: "f1"
      })

      assert Files.get_blob(ref["hash"]).reference_count == 1

      # Set on ancestor "docs" should delete descendants including the file
      Dust.Sync.write(store.id, %{
        op: :set,
        path: "docs",
        value: "replaced",
        device_id: "d",
        client_op_id: "f2"
      })

      assert Files.get_blob(ref["hash"]).reference_count == 0
    end
  end

  describe "blob_path/1" do
    test "uses sharded directory layout" do
      hash = "sha256:abcdef1234567890"
      path = Files.blob_path(hash)

      assert path =~ "ab"
      assert path =~ "cd"
      assert String.ends_with?(path, hash)
    end
  end
end
