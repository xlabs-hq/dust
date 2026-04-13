defmodule DustWeb.OAuth.RedirectUriValidatorTest do
  use ExUnit.Case, async: false

  alias DustWeb.OAuth.RedirectUriValidator

  describe "valid?/1 loopback" do
    test "accepts http://127.0.0.1 with any port and path" do
      assert RedirectUriValidator.valid?("http://127.0.0.1/cb")
      assert RedirectUriValidator.valid?("http://127.0.0.1:33418/cb")
      assert RedirectUriValidator.valid?("http://127.0.0.1:1/")
    end

    test "accepts http://localhost with any port and path" do
      assert RedirectUriValidator.valid?("http://localhost/cb")
      assert RedirectUriValidator.valid?("http://localhost:8080/oauth/callback")
    end

    test "accepts http://[::1]" do
      assert RedirectUriValidator.valid?("http://[::1]:33418/cb")
    end
  end

  describe "valid?/1 non-loopback http" do
    test "rejects http://example.com/cb" do
      refute RedirectUriValidator.valid?("http://example.com/cb")
    end

    test "rejects http scheme for non-loopback hosts generally" do
      refute RedirectUriValidator.valid?("http://attacker.example/cb")
      refute RedirectUriValidator.valid?("http://127.0.0.1.attacker.example/cb")
    end
  end

  describe "valid?/1 https allowlist" do
    setup do
      previous = Application.get_env(:dust, :mcp_redirect_uri_allowlist, [])
      on_exit(fn -> Application.put_env(:dust, :mcp_redirect_uri_allowlist, previous) end)
      :ok
    end

    test "rejects arbitrary https URI when allowlist is empty" do
      Application.put_env(:dust, :mcp_redirect_uri_allowlist, [])
      refute RedirectUriValidator.valid?("https://attacker.example/cb")
    end

    test "accepts https URI matching a configured prefix" do
      Application.put_env(:dust, :mcp_redirect_uri_allowlist, [
        "https://claude.ai/api/mcp/auth_callback"
      ])

      assert RedirectUriValidator.valid?("https://claude.ai/api/mcp/auth_callback")
      assert RedirectUriValidator.valid?("https://claude.ai/api/mcp/auth_callback?x=1")
    end

    test "rejects https URI that does not match any configured prefix" do
      Application.put_env(:dust, :mcp_redirect_uri_allowlist, [
        "https://claude.ai/api/mcp/auth_callback"
      ])

      refute RedirectUriValidator.valid?("https://attacker.example/cb")
      refute RedirectUriValidator.valid?("https://claude.ai.attacker.example/cb")
    end
  end

  describe "valid?/1 bad input" do
    test "rejects nil and non-binaries" do
      refute RedirectUriValidator.valid?(nil)
      refute RedirectUriValidator.valid?(123)
      refute RedirectUriValidator.valid?(%{})
    end

    test "rejects malformed strings" do
      refute RedirectUriValidator.valid?("not a uri")
      refute RedirectUriValidator.valid?("javascript:alert(1)")
      refute RedirectUriValidator.valid?("ftp://127.0.0.1/cb")
    end
  end
end
