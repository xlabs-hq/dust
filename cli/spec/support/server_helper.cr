require "json"

# Helper module for integration tests that run against a live Dust server.
#
# Required environment variables:
#   DUST_TEST_TOKEN  - A valid API token for the test server
#
# Optional environment variables:
#   DUST_TEST_SERVER - WebSocket URL (default: ws://localhost:7755/ws/sync)
#   DUST_TEST_STORE  - Store name to use (default: test/cli-integration)
#
# Usage:
#   DUST_TEST_TOKEN=tok_abc123 crystal spec spec/integration_spec.cr

module IntegrationHelper
  DUST_BIN    = File.expand_path("../../bin/dust", __DIR__)
  TEST_TOKEN  = ENV["DUST_TEST_TOKEN"]?
  TEST_SERVER = ENV["DUST_TEST_SERVER"]? || "ws://localhost:7755/ws/sync"
  TEST_STORE  = ENV["DUST_TEST_STORE"]? || "test/cli-integration"

  def self.available? : Bool
    !!TEST_TOKEN
  end

  # Run the dust CLI binary with the given arguments.
  # Returns {stdout, stderr, exit_code}.
  def self.run_dust(*args : String) : {String, String, Int32}
    run_dust(args.to_a)
  end

  def self.run_dust(args : Array(String)) : {String, String, Int32}
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    env = {
      "DUST_API_KEY" => TEST_TOKEN.not_nil!,
    }

    status = Process.run(
      DUST_BIN,
      args,
      env: env,
      output: stdout,
      error: stderr,
    )

    {stdout.to_s, stderr.to_s, status.exit_code}
  end

  # Run dust and assert success (exit code 0). Returns stdout.
  def self.run_dust!(*args : String) : String
    stdout, stderr, code = run_dust(*args)
    if code != 0
      raise "dust #{args.join(" ")} failed (exit #{code}):\nstdout: #{stdout}\nstderr: #{stderr}"
    end
    stdout
  end

  # Generate a unique path prefix to avoid collisions between test runs.
  def self.unique_prefix : String
    "itest.#{Time.utc.to_unix_ms}.#{Random::Secure.hex(4)}"
  end
end
