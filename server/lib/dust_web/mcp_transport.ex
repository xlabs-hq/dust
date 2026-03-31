defmodule DustWeb.MCPTransport do
  @moduledoc """
  Thin wrapper around GenMCP's Streamable HTTP transport for Phoenix router compatibility.
  """

  require GenMCP.Transport.StreamableHTTP
  GenMCP.Transport.StreamableHTTP.defplug(__MODULE__.Plug)

  defdelegate init(opts), to: __MODULE__.Plug
  defdelegate call(conn, opts), to: __MODULE__.Plug
end
