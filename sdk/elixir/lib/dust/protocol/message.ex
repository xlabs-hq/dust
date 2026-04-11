defmodule Dust.Protocol.Message do
  @doc "Build a hello message."
  def hello(capver, device_id, token) do
    %{type: "hello", capver: capver, device_id: device_id, token: token}
  end

  @doc "Build a hello response."
  def hello_response(capver_min, capver_max, your_capver, stores) do
    %{
      type: "hello_response",
      capver_min: capver_min,
      capver_max: capver_max,
      your_capver: your_capver,
      stores: stores
    }
  end

  @doc "Build a join message."
  def join(store, last_store_seq) do
    %{type: "join", store: store, last_store_seq: last_store_seq}
  end

  @doc "Build a write message."
  def write(store, op, path, value, device_id, client_op_id) do
    %{
      type: "write",
      store: store,
      op: to_string(op),
      path: path,
      value: value,
      device_id: device_id,
      client_op_id: client_op_id
    }
  end

  @doc "Build a canonical event."
  def event(store, store_seq, op, path, value, device_id, client_op_id) do
    %{
      type: "event",
      store: store,
      store_seq: store_seq,
      op: to_string(op),
      path: path,
      value: value,
      device_id: device_id,
      client_op_id: client_op_id
    }
  end

  @doc "Build an error message."
  def error(code, message) do
    %{type: "error", code: code, message: message}
  end
end
