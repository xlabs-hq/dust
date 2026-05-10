defmodule DustEcto.TransportTest do
  use ExUnit.Case, async: false

  alias DustEcto.Transport

  setup do
    # Snapshot + restore env across tests so async: false safe.
    keys = [:dust_facade, :store, :base_url, :token]
    snapshot = Enum.into(keys, %{}, fn k -> {k, Application.get_env(:dust_ecto, k)} end)

    on_exit(fn ->
      Enum.each(snapshot, fn
        {k, nil} -> Application.delete_env(:dust_ecto, k)
        {k, v} -> Application.put_env(:dust_ecto, k, v)
      end)
    end)

    :ok
  end

  describe "pick/0" do
    test "explicit dust_facade config wins" do
      Application.put_env(:dust_ecto, :dust_facade, MyApp.Dust)
      assert {DustEcto.Transport.SDK, %{facade: MyApp.Dust}} = Transport.pick()
    end

    test "without dust_facade, falls back to HTTP if base_url + token are set" do
      Application.delete_env(:dust_ecto, :dust_facade)
      Application.put_env(:dust_ecto, :base_url, "https://example.test")
      Application.put_env(:dust_ecto, :token, "tok_x")
      Application.put_env(:dust_ecto, :store, "myorg/mystore")

      assert {DustEcto.Transport.HTTP, config} = Transport.pick()
      assert config.base_url == "https://example.test"
      assert config.token == "tok_x"
    end

    test "raises a clear error if HTTP mode is selected without base_url" do
      Application.delete_env(:dust_ecto, :dust_facade)
      Application.delete_env(:dust_ecto, :base_url)
      Application.put_env(:dust_ecto, :token, "tok_x")

      assert_raise ArgumentError, ~r/:base_url/, fn -> Transport.pick() end
    end
  end

  describe "store!/0" do
    test "returns the configured store" do
      Application.put_env(:dust_ecto, :store, "alice/main")
      assert Transport.store!() == "alice/main"
    end

    test "raises when not configured" do
      Application.delete_env(:dust_ecto, :store)
      assert_raise ArgumentError, ~r/:store/, fn -> Transport.store!() end
    end
  end
end
