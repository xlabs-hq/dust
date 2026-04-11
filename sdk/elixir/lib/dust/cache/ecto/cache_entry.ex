if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Dust.Cache.Ecto.CacheEntry do
    use Ecto.Schema

    @primary_key false
    schema "dust_cache" do
      field :store, :string
      field :path, :string
      field :value, :string
      field :type, :string
      field :seq, :integer
    end
  end
end
