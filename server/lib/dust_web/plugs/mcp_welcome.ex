defmodule DustWeb.Plugs.McpWelcome do
  @moduledoc """
  Intercepts browser `GET /mcp` requests and returns a friendly HTML
  landing page explaining what this endpoint is.

  An MCP endpoint speaks JSON-RPC over HTTP / SSE, so a raw 401 confuses
  humans who paste the URL into a browser tab. We detect that case
  (Accept includes `text/html` and neither `application/json` nor
  `text/event-stream`) and respond with a welcome page instead of
  falling through to the auth plug.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    if browser_request?(conn) do
      conn
      |> put_resp_header("cache-control", "public, max-age=300")
      |> put_resp_content_type("text/html")
      |> send_resp(200, render())
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp browser_request?(conn) do
    accept =
      case get_req_header(conn, "accept") do
        [value | _] -> String.downcase(value)
        [] -> ""
      end

    String.contains?(accept, "text/html") and
      not String.contains?(accept, "application/json") and
      not String.contains?(accept, "text/event-stream")
  end

  defp render do
    base_url = DustWeb.Endpoint.url()
    mcp_url = base_url <> "/mcp"
    home_url = base_url <> "/"

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <meta name="robots" content="noindex" />
      <title>Dust MCP Server</title>
      <link rel="icon" href="/favicon.ico" />
      <style>
        :root {
          color-scheme: light dark;
          --bg: #fafafa;
          --fg: #18181b;
          --muted: #71717a;
          --card: #ffffff;
          --border: #e4e4e7;
          --accent: #18181b;
          --accent-fg: #fafafa;
          --code-bg: #f4f4f5;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #09090b;
            --fg: #fafafa;
            --muted: #a1a1aa;
            --card: #18181b;
            --border: #27272a;
            --accent: #fafafa;
            --accent-fg: #18181b;
            --code-bg: #27272a;
          }
        }
        * { box-sizing: border-box; }
        html, body {
          margin: 0;
          padding: 0;
          background: var(--bg);
          color: var(--fg);
          font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
          line-height: 1.55;
        }
        main {
          max-width: 640px;
          margin: 0 auto;
          padding: 64px 24px;
        }
        .badge {
          display: inline-block;
          font-size: 12px;
          font-weight: 500;
          letter-spacing: 0.04em;
          text-transform: uppercase;
          color: var(--muted);
          border: 1px solid var(--border);
          border-radius: 999px;
          padding: 4px 10px;
          margin-bottom: 24px;
        }
        h1 {
          font-size: 32px;
          line-height: 1.2;
          margin: 0 0 12px;
          letter-spacing: -0.02em;
        }
        .lede {
          color: var(--muted);
          font-size: 17px;
          margin: 0 0 32px;
        }
        .card {
          background: var(--card);
          border: 1px solid var(--border);
          border-radius: 12px;
          padding: 20px 24px;
          margin: 0 0 24px;
        }
        .card h2 {
          font-size: 14px;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.06em;
          color: var(--muted);
          margin: 0 0 12px;
        }
        .url {
          display: flex;
          align-items: center;
          gap: 12px;
          font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
          font-size: 15px;
          background: var(--code-bg);
          border-radius: 8px;
          padding: 12px 14px;
          word-break: break-all;
        }
        button.copy {
          font: inherit;
          font-family: ui-sans-serif, system-ui, sans-serif;
          font-size: 13px;
          background: var(--accent);
          color: var(--accent-fg);
          border: none;
          border-radius: 6px;
          padding: 6px 12px;
          cursor: pointer;
          flex-shrink: 0;
        }
        button.copy:hover { opacity: 0.9; }
        button.copy:active { transform: translateY(1px); }
        ol { padding-left: 20px; margin: 0; }
        ol li { margin: 6px 0; }
        h3 {
          font-size: 15px;
          font-weight: 600;
          margin: 0 0 8px;
        }
        h3 + p, h3 + ol { margin-top: 0; }
        a { color: var(--fg); text-decoration: underline; text-decoration-color: var(--muted); }
        a:hover { text-decoration-color: var(--fg); }
        footer {
          margin-top: 32px;
          font-size: 13px;
          color: var(--muted);
        }
      </style>
    </head>
    <body>
      <main>
        <span class="badge">MCP Endpoint</span>
        <h1>You found the Dust MCP server.</h1>
        <p class="lede">
          This URL isn't meant to be opened in a browser &mdash; it speaks
          the <a href="https://modelcontextprotocol.io" rel="noopener">Model Context Protocol</a>,
          which lets AI agents connect to Dust as a tool.
        </p>

        <div class="card">
          <h2>Server URL</h2>
          <div class="url">
            <span id="mcp-url">#{mcp_url}</span>
            <button class="copy" type="button" onclick="navigator.clipboard.writeText(document.getElementById('mcp-url').textContent).then(()=>{this.textContent='Copied';setTimeout(()=>this.textContent='Copy',1200)})">Copy</button>
          </div>
        </div>

        <div class="card">
          <h2>How to connect</h2>
          <p style="margin:0;color:var(--muted);">
            In your MCP client (Claude Desktop, ChatGPT, Cursor, &hellip;):
          </p>
          <ol style="margin-top:8px;">
            <li>Add a new MCP server and paste the URL above.</li>
            <li>Sign in with your Dust account when prompted &mdash; the client handles the OAuth handshake automatically.</li>
            <li>Your client will discover the available tools and you're ready to go.</li>
          </ol>
        </div>

        <footer>
          Not what you were after? Head back to <a href="#{home_url}">Dust</a>.
        </footer>
      </main>
    </body>
    </html>
    """
  end
end
