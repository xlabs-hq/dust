defmodule Dust.Files do
  @moduledoc """
  Content-addressed blob storage for file uploads.

  Files are stored on the local filesystem (MVP) with a sharded directory
  layout: `<blob_dir>/<ab>/<cd>/sha256:abcd...`.

  Content addressing means identical files are stored once regardless of how
  many store entries reference them.
  """

  import Ecto.Query
  alias Dust.Repo
  alias Dust.Files.Blob

  @blob_dir Application.compile_env(:dust, :blob_dir, "priv/blobs")

  def blob_dir, do: @blob_dir

  @doc """
  Upload binary content and return a file reference map.

  Options:
    - `:content_type` - MIME type (default: "application/octet-stream")
    - `:filename` - original filename
  """
  def upload(content, opts \\ []) when is_binary(content) do
    hash = "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
    blob_path = blob_path(hash)
    content_type = opts[:content_type] || "application/octet-stream"
    filename = opts[:filename]

    # Content-addressed: skip disk write if already exists
    unless File.exists?(blob_path) do
      File.mkdir_p!(Path.dirname(blob_path))
      File.write!(blob_path, content)
    end

    # Upsert blob record — increment reference_count if it already exists
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(
      %Blob{
        hash: hash,
        size: byte_size(content),
        content_type: content_type,
        filename: filename,
        reference_count: 1,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [inc: [reference_count: 1], set: [updated_at: now]],
      conflict_target: [:hash]
    )

    ref = %{
      "_type" => "file",
      "hash" => hash,
      "size" => byte_size(content),
      "content_type" => content_type,
      "filename" => filename,
      "uploaded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, ref}
  end

  @doc """
  Upload a file from the local filesystem.

  Detects content_type from extension if not provided.
  """
  def upload_from_path(file_path, opts \\ []) do
    content = File.read!(file_path)
    filename = opts[:filename] || Path.basename(file_path)
    content_type = opts[:content_type] || mime_from_path(file_path)
    upload(content, Keyword.merge(opts, filename: filename, content_type: content_type))
  end

  @doc "Decrement reference count for a blob. Called when a file entry is overwritten or deleted."
  def decrement_ref(hash) when is_binary(hash) do
    from(b in Blob, where: b.hash == ^hash)
    |> Repo.update_all(inc: [reference_count: -1])

    :ok
  end

  def decrement_ref(_), do: :ok

  @doc "Download blob content by hash."
  def download(hash) do
    path = blob_path(hash)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "Check whether a blob exists on disk."
  def exists?(hash) do
    File.exists?(blob_path(hash))
  end

  @doc "Get the blob metadata record from the database."
  def get_blob(hash) do
    Repo.get(Blob, hash)
  end

  @doc "Return the on-disk path for a given hash."
  def blob_path(hash) do
    clean = String.replace_prefix(hash, "sha256:", "")
    prefix = String.slice(clean, 0, 2)
    subdir = String.slice(clean, 2, 2)
    Path.join([@blob_dir, prefix, subdir, hash])
  end

  # Simple MIME type detection from file extension.
  # No external dependency needed for MVP.
  @mime_types %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".svg" => "image/svg+xml",
    ".pdf" => "application/pdf",
    ".json" => "application/json",
    ".txt" => "text/plain",
    ".html" => "text/html",
    ".css" => "text/css",
    ".js" => "application/javascript",
    ".xml" => "application/xml",
    ".zip" => "application/zip",
    ".csv" => "text/csv",
    ".md" => "text/markdown",
    ".mp3" => "audio/mpeg",
    ".mp4" => "video/mp4",
    ".wav" => "audio/wav",
    ".doc" => "application/msword",
    ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".xls" => "application/vnd.ms-excel",
    ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  }

  defp mime_from_path(path) do
    ext = path |> Path.extname() |> String.downcase()
    Map.get(@mime_types, ext, "application/octet-stream")
  end
end
