defmodule Dust.Protocol.Op do
  @enforce_keys [:op, :path, :device_id, :client_op_id]
  defstruct [:op, :path, :value, :device_id, :client_op_id]

  @core_ops [:set, :delete, :merge, :increment, :add, :remove]

  def valid_op?(op), do: op in @core_ops

  def core_ops, do: @core_ops

  def new(attrs) when is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
