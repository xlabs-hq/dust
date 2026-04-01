require "./spec_helper"
require "./support/server_helper"

# Integration tests that exercise the compiled CLI binary against a running
# Dust server. These tests are skipped when DUST_TEST_TOKEN is not set.
#
# Run:
#   cd cli && crystal build src/dust.cr -o bin/dust
#   DUST_TEST_TOKEN=tok_xxx crystal spec spec/integration_spec.cr

describe "Integration" do
  store = IntegrationHelper::TEST_STORE

  describe "put and get round-trip" do
    it "stores a JSON value and retrieves it" do
      pending!("DUST_TEST_TOKEN not set") unless IntegrationHelper.available?

      prefix = IntegrationHelper.unique_prefix
      path = "#{prefix}.hello"

      # Put a value
      result = IntegrationHelper.run_dust!("put", store, path, %({"title":"Hello World"}))
      result.should contain("OK")

      # Get it back
      result = IntegrationHelper.run_dust!("get", store, path)
      parsed = JSON.parse(result)
      parsed["title"].as_s.should eq("Hello World")
    end
  end

  describe "merge" do
    it "merges additional keys into an existing value" do
      pending!("DUST_TEST_TOKEN not set") unless IntegrationHelper.available?

      prefix = IntegrationHelper.unique_prefix
      path = "#{prefix}.mergeable"

      # Put initial value
      IntegrationHelper.run_dust!("put", store, path, %({"name":"Alice"}))

      # Merge additional keys
      result = IntegrationHelper.run_dust!("merge", store, path, %({"age":30}))
      result.should contain("OK")

      # Get and verify both keys are present
      result = IntegrationHelper.run_dust!("get", store, path)
      parsed = JSON.parse(result)
      parsed["name"].as_s.should eq("Alice")
      parsed["age"].as_i.should eq(30)
    end
  end

  describe "delete" do
    it "removes a value so get returns not found" do
      pending!("DUST_TEST_TOKEN not set") unless IntegrationHelper.available?

      prefix = IntegrationHelper.unique_prefix
      path = "#{prefix}.deleteme"

      # Put, then delete
      IntegrationHelper.run_dust!("put", store, path, %({"temp":true}))
      result = IntegrationHelper.run_dust!("delete", store, path)
      result.should contain("OK")

      # Get should fail (exit 1, error message)
      stdout, stderr, code = IntegrationHelper.run_dust("get", store, path)
      code.should eq(1)
      stderr.should contain("not found")
    end
  end

  describe "increment" do
    it "increments a counter and retrieves the value" do
      pending!("DUST_TEST_TOKEN not set") unless IntegrationHelper.available?

      prefix = IntegrationHelper.unique_prefix
      path = "#{prefix}.counter"

      # Increment three times
      IntegrationHelper.run_dust!("increment", store, path)
      IntegrationHelper.run_dust!("increment", store, path)
      result = IntegrationHelper.run_dust!("increment", store, path, "5")
      result.should contain("OK")

      # Get the counter value
      result = IntegrationHelper.run_dust!("get", store, path)
      # Counter value should be 1 + 1 + 5 = 7
      parsed = JSON.parse(result)
      parsed.as_i.should eq(7)
    end
  end

  describe "enum" do
    it "lists entries matching a glob pattern" do
      pending!("DUST_TEST_TOKEN not set") unless IntegrationHelper.available?

      prefix = IntegrationHelper.unique_prefix

      # Put multiple entries under the same prefix
      IntegrationHelper.run_dust!("put", store, "#{prefix}.posts.a", %({"id":1}))
      IntegrationHelper.run_dust!("put", store, "#{prefix}.posts.b", %({"id":2}))
      IntegrationHelper.run_dust!("put", store, "#{prefix}.posts.c", %({"id":3}))
      IntegrationHelper.run_dust!("put", store, "#{prefix}.other.x", %({"id":99}))

      # Enum with glob should match only posts
      result = IntegrationHelper.run_dust!("enum", store, "#{prefix}.posts.*")
      parsed = JSON.parse(result)
      parsed.as_h.size.should eq(3)
      parsed.as_h.keys.should contain("#{prefix}.posts.a")
      parsed.as_h.keys.should contain("#{prefix}.posts.b")
      parsed.as_h.keys.should contain("#{prefix}.posts.c")
      parsed.as_h.keys.should_not contain("#{prefix}.other.x")
    end
  end

  describe "put overwrite" do
    it "overwrites a previous value completely" do
      pending!("DUST_TEST_TOKEN not set") unless IntegrationHelper.available?

      prefix = IntegrationHelper.unique_prefix
      path = "#{prefix}.overwrite"

      # Put initial value with multiple keys
      IntegrationHelper.run_dust!("put", store, path, %({"a":1,"b":2}))

      # Overwrite with a different value
      IntegrationHelper.run_dust!("put", store, path, %({"c":3}))

      # Get should show only the new value (set semantics, not merge)
      result = IntegrationHelper.run_dust!("get", store, path)
      parsed = JSON.parse(result)
      parsed.as_h.has_key?("c").should be_true
      parsed.as_h.has_key?("a").should be_false
    end
  end

  describe "version" do
    it "prints version without needing a token" do
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(
        IntegrationHelper::DUST_BIN,
        ["version"],
        output: stdout,
        error: stderr,
      )
      status.exit_code.should eq(0)
      stdout.to_s.should contain("dust")
    end
  end
end
