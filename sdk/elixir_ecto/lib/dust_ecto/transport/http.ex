defmodule DustEcto.Transport.HTTP do
  @moduledoc """
  Stateless HTTP transport — Req against the Dust REST API. Suitable
  for one-shot scripts, release tasks, and contexts where the WS
  supervisor isn't running. No realtime: `subscribe/3` returns
  `{:error, :not_supported}`.

  All bodies are encoded/decoded with the stdlib `JSON` module
  (Elixir 1.18+). The token comes from `config :dustlayer_ecto, :token`;
  base URL from `:base_url`.
  """

  @behaviour DustEcto.Transport

  alias Dust.Protocol.Path, as: DustPath
  alias DustEcto.Error

  @impl DustEcto.Transport
  def list(store, pattern, opts) do
    config = pop_config(opts)
    {org, name} = split_store!(store)

    query =
      opts
      |> Keyword.drop([:config])
      |> normalize_list_opts(pattern)

    case request(:get, config, "/api/stores/#{org}/#{name}/entries", params: query) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           items: render_items(body["items"]),
           next_cursor: body["next_cursor"]
         }}

      err ->
        translate_error(err)
    end
  end

  @impl DustEcto.Transport
  def get(store, path) do
    config = pop_config([])
    {org, name} = split_store!(store)
    url_path = "/api/stores/#{org}/#{name}/entries/" <> path_to_url_segments(path)

    case request(:get, config, url_path) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           path: body["path"],
           value: body["value"],
           type: body["type"],
           revision: body["revision"]
         }}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      err ->
        translate_error(err)
    end
  end

  @impl DustEcto.Transport
  def exists?(store, path) do
    config = pop_config([])
    {org, name} = split_store!(store)
    url_path = "/api/stores/#{org}/#{name}/entries/" <> path_to_url_segments(path)

    case request(:head, config, url_path) do
      {:ok, %{status: 200}} -> {:ok, true}
      {:ok, %{status: 404}} -> {:ok, false}
      {:ok, %{status: 405}} -> exists_via_keys(store, path)
      err -> translate_error(err)
    end
  end

  # HEAD wasn't always supported on the Dust server — pre-0c55375
  # deploys 405 it. Fall back to the cheapest existence query the
  # server has always supported: a one-key listing under
  # `<path>/**`. Bounded (1 key, no values), no body decode.
  defp exists_via_keys(store, path) do
    case list(store, "#{path}/**", select: :keys, limit: 1) do
      {:ok, %{items: [_ | _]}} -> {:ok, true}
      {:ok, %{items: []}} -> {:ok, false}
      err -> err
    end
  end

  @impl DustEcto.Transport
  def put(store, path, value, opts) do
    config = pop_config(opts)
    {org, name} = split_store!(store)
    url_path = "/api/stores/#{org}/#{name}/entries/" <> path_to_url_segments(path)
    headers = if_match_header(opts)

    case request(:put, config, url_path, body: encode_json(value), headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, %{store_seq: body["store_seq"]}}

      {:ok, %{status: 412, body: body}} ->
        {:error,
         Error.new(:conflict, %{current_revision: body["current_revision"]}, retryable?: false)}

      err ->
        translate_error(err)
    end
  end

  @impl DustEcto.Transport
  def delete(store, path, opts) do
    config = pop_config(opts)
    {org, name} = split_store!(store)
    url_path = "/api/stores/#{org}/#{name}/entries/" <> path_to_url_segments(path)
    headers = if_match_header(opts)

    case request(:delete, config, url_path, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, %{store_seq: body["store_seq"]}}

      {:ok, %{status: 412, body: body}} ->
        {:error,
         Error.new(:conflict, %{current_revision: body["current_revision"]}, retryable?: false)}

      err ->
        translate_error(err)
    end
  end

  @impl DustEcto.Transport
  def batch_write(store, ops, opts) do
    config = pop_config(opts)
    {org, name} = split_store!(store)
    url_path = "/api/stores/#{org}/#{name}/entries/batch_write"

    body = encode_json(%{ops: Enum.map(ops, &normalize_batch_op/1)})

    case request(:post, config, url_path, body: body) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           store_seq: body["store_seq"],
           ops: body["ops"]
         }}

      {:ok, %{status: 412, body: body}} ->
        {:error,
         Error.new(
           :conflict,
           %{
             op_index: body["op_index"],
             path: body["path"],
             current_revision: body["current_revision"]
           },
           retryable?: false
         )}

      err ->
        translate_error(err)
    end
  end

  @impl DustEcto.Transport
  def subscribe(_store, _pattern, _callback) do
    {:error,
     Error.new(
       :not_supported,
       "subscribe is not available over the HTTP transport — use SDK mode (Dust.Supervisor) for realtime",
       retryable?: false
     )}
  end

  @impl DustEcto.Transport
  def unsubscribe(_store, _ref), do: :ok

  # --- internals ---

  defp pop_config(opts) do
    config =
      Keyword.get(opts, :config) ||
        case DustEcto.Transport.pick() do
          {DustEcto.Transport.HTTP, config} ->
            config

          _ ->
            raise ArgumentError,
                  "DustEcto.Transport.HTTP called without an active HTTP config. " <>
                    "Set :base_url and :token under :dustlayer_ecto."
        end

    # Test-only: callers can install a Req.Test stub via Application
    # config so requests get intercepted without a real HTTP server.
    case Application.get_env(:dustlayer_ecto, :req_plug) do
      nil -> config
      plug -> Map.put(config, :plug, plug)
    end
  end

  defp split_store!(store) when is_binary(store) do
    case String.split(store, "/", parts: 2) do
      [org, name] when org != "" and name != "" -> {org, name}
      _ -> raise ArgumentError, "store must be 'org/name' (got #{inspect(store)})"
    end
  end

  defp path_to_url_segments(path) when is_binary(path) do
    # Path is canonical slash-rendered (`links/foo/title`). We split on
    # `/` and keep each *rendered* piece — `~0` and `~1` are already
    # URL-safe (RFC 3986 unreserved + digit) — then percent-encode any
    # remaining unsafe bytes. The server's wildcard route receives the
    # rendered pieces back and rejoins them with `/`, so `~1` survives
    # as the JSON-Pointer escape for a literal slash inside a segment.
    #
    # Re-parsing into raw segments and URL-encoding `/` to `%2F` is
    # wrong here: Phoenix decodes `%2F` to `/` before splitting, so a
    # segment containing a literal slash ends up split in two.
    #
    # URI.encode_www_form/1 turns space into `+`, which is correct for
    # `application/x-www-form-urlencoded` query strings but wrong in
    # a URL path segment — RFC 3986 / Plug treat `+` literally there.
    # URI.encode/2 with a path-safe character predicate produces the
    # right %20 encoding.
    case DustPath.parse_rendered(path) do
      {:ok, _segments} ->
        path
        |> String.split("/")
        |> Enum.map_join("/", &encode_rendered_piece/1)

      _ ->
        raise ArgumentError, "invalid path #{inspect(path)}"
    end
  end

  defp encode_rendered_piece(piece) do
    URI.encode(piece, &path_segment_safe?/1)
  end

  # Characters allowed unencoded in a URL path segment. Per RFC 3986
  # this would be `unreserved / sub-delims / :@`, but we additionally
  # percent-encode `+` because several HTTP servers (including older
  # Plug versions) treat `+` in a path as a space — a leftover from
  # www-form encoding semantics. Encoding it as `%2B` is universally
  # safe.
  defp path_segment_safe?(ch) do
    URI.char_unreserved?(ch) or ch in ~c"!$&'()*,;=:@"
  end

  defp normalize_list_opts(opts, pattern) do
    base = [pattern: pattern]

    Enum.reduce([:limit, :after, :order, :select, :from, :to], base, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, val} -> Keyword.put(acc, key, val)
        :error -> acc
      end
    end)
  end

  defp if_match_header(opts) do
    case Keyword.fetch(opts, :if_match) do
      {:ok, n} when is_integer(n) -> [{"if-match", Integer.to_string(n)}]
      _ -> []
    end
  end

  defp normalize_batch_op(%{op: op, path: path, value: value} = m),
    do: maybe_put_if_match(%{op: to_string(op), path: path, value: value}, m)

  defp normalize_batch_op(%{op: op, path: path} = m),
    do: maybe_put_if_match(%{op: to_string(op), path: path}, m)

  defp maybe_put_if_match(out, %{if_match: n}) when is_integer(n),
    do: Map.put(out, :if_match, n)

  defp maybe_put_if_match(out, _), do: out

  defp encode_json(value), do: JSON.encode!(value)

  defp request(method, config, path, opts \\ []) do
    url = config.base_url <> path
    headers = [{"authorization", "Bearer " <> config.token}] ++ Keyword.get(opts, :headers, [])

    body = Keyword.get(opts, :body)
    params = Keyword.get(opts, :params, [])

    # Auto-retry is off here — dustlayer_ecto surfaces transport errors
    # (429, 5xx) to the caller via the %Error{retryable?:} flag so the
    # *application* decides whether to retry. Auto-retry inside Req
    # would silently double-write non-idempotent ops on a flaky network.
    #
    # Timeouts are app-configurable so callers serving web requests can
    # bound how long a Dust outage stalls them. Defaults match Req's.
    req_opts =
      [
        method: method,
        url: url,
        headers: headers,
        params: params,
        decode_body: false,
        retry: false,
        receive_timeout: Application.get_env(:dustlayer_ecto, :receive_timeout, 15_000),
        connect_options: [timeout: Application.get_env(:dustlayer_ecto, :connect_timeout, 30_000)]
      ]
      |> maybe_put_body(method, body)
      |> maybe_put_test_plug(config)

    case Req.request(req_opts) do
      {:ok, %Req.Response{} = resp} ->
        decoded =
          case resp.body do
            "" -> nil
            nil -> nil
            bin when is_binary(bin) -> safe_decode_json(bin)
            other -> other
          end

        {:ok, %{status: resp.status, body: decoded, headers: resp.headers}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp maybe_put_body(opts, method, body)
       when method in [:put, :post, :delete] and not is_nil(body),
       do:
         opts
         |> Keyword.put(:body, body)
         |> Keyword.update(:headers, [{"content-type", "application/json"}], fn h ->
           [{"content-type", "application/json"} | h]
         end)

  defp maybe_put_body(opts, _, _), do: opts

  # Test-only escape hatch: callers can stash a `:plug` (or `:req_options`)
  # in the config map so tests can route requests through Req.Test.stub
  # without spinning up an HTTP server. Production paths never hit this.
  defp maybe_put_test_plug(opts, %{plug: plug}), do: Keyword.put(opts, :plug, plug)
  defp maybe_put_test_plug(opts, _), do: opts

  defp safe_decode_json(""), do: nil

  defp safe_decode_json(bin) do
    case JSON.decode(bin) do
      {:ok, term} -> term
      _ -> bin
    end
  end

  defp render_items(items) when is_list(items) do
    Enum.map(items, fn
      %{"path" => p, "value" => v, "type" => t, "revision" => r} ->
        %{path: p, value: v, type: t, revision: r}

      key when is_binary(key) ->
        key

      other ->
        other
    end)
  end

  defp render_items(_), do: []

  defp translate_error({:ok, %{status: 401}}),
    do: {:error, Error.new(:unauthorized, nil)}

  defp translate_error({:ok, %{status: 403}}),
    do: {:error, Error.new(:unauthorized, "forbidden", retryable?: false)}

  defp translate_error({:ok, %{status: 429, body: body, headers: headers}}) do
    {:error,
     Error.new(
       :rate_limited,
       %{retry_after: header_value(headers, "retry-after"), body: body},
       retryable?: true
     )}
  end

  # A 404 that *reaches* translate_error has fallen past every per-action
  # `{:ok, %{status: 404}}` clause — meaning the action treats 404 as a
  # transport-level failure, not an entity miss. Almost always: the
  # deployed server doesn't have that route (e.g. older Dust before
  # DELETE/batch_write shipped). Distinct from `:not_found`, which is
  # reserved for entity misses inside GET-style actions.
  defp translate_error({:ok, %{status: 404, body: body}}),
    do:
      {:error,
       Error.new(
         :not_implemented,
         %{
           status: 404,
           body: body,
           hint: "server doesn't expose this route — likely a deploy lag"
         },
         retryable?: false
       )}

  defp translate_error({:ok, %{status: status, body: body}}) when status >= 400 and status < 500,
    do: {:error, Error.new(:invalid_params, %{status: status, body: body}, retryable?: false)}

  defp translate_error({:ok, %{status: status, body: body}}) when status >= 500,
    do: {:error, Error.new(:http, %{status: status, body: body}, retryable?: true)}

  defp translate_error({:error, exception}),
    do: {:error, Error.new(:network, exception, retryable?: true)}

  # Req represents headers as either {k, v} tuples or {k, [v, ...]} lists
  # depending on version; pull a single scalar out either way.
  defp header_value(headers, name) when is_list(headers) do
    name_dn = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == name_dn do
        case v do
          [first | _] -> first
          val when is_binary(val) -> val
          _ -> nil
        end
      end
    end)
  end

  defp header_value(headers, name) when is_map(headers) do
    case Map.get(headers, String.downcase(name)) || Map.get(headers, name) do
      [first | _] -> first
      val when is_binary(val) -> val
      _ -> nil
    end
  end

  defp header_value(_, _), do: nil
end
