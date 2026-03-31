defmodule Dust.FileRef do
  @moduledoc "Reference to a file stored in Dust. Returned by Dust.get/2 when the value is a file."

  defstruct [:hash, :size, :content_type, :filename, :uploaded_at, :_server_url, :_token]

  @doc "Create a FileRef from a raw map (as stored in cache)."
  def from_map(map, opts \\ []) do
    %__MODULE__{
      hash: map["hash"],
      size: map["size"],
      content_type: map["content_type"],
      filename: map["filename"],
      uploaded_at: map["uploaded_at"],
      _server_url: opts[:server_url],
      _token: opts[:token]
    }
  end

  @doc "Fetch the file content as binary over HTTP."
  def fetch(%__MODULE__{} = ref) do
    url = "#{ref._server_url}/api/files/#{URI.encode(ref.hash)}"
    headers = [{"authorization", "Bearer #{ref._token}"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Download the file to a local path."
  def download(%__MODULE__{} = ref, path) do
    case fetch(ref) do
      {:ok, content} -> File.write(path, content)
      error -> error
    end
  end
end
