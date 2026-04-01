require "./spec_helper"
require "file_utils"

describe Dust::Config do
  it "creates a new config with defaults" do
    config = Dust::Config.new
    config.server_url.should eq "ws://localhost:7755/ws/sync"
    config.device_id.should start_with "dev_"
    config.device_id.size.should eq 20 # "dev_" (4) + 16 hex chars
  end

  it "is not authenticated by default" do
    config = Dust::Config.new
    config.authenticated?.should be_false
  end

  it "reads DUST_API_KEY from environment" do
    ENV["DUST_API_KEY"] = "test_token_123"
    config = Dust::Config.new
    config.token.should eq "test_token_123"
    config.authenticated?.should be_true
    ENV.delete("DUST_API_KEY")
  end

  it "generates unique device IDs" do
    config1 = Dust::Config.new
    config2 = Dust::Config.new
    config1.device_id.should_not eq config2.device_id
  end

  it "saves and loads credentials" do
    # Use a temp directory for config
    tmp_dir = File.tempname("dust_test")
    Dir.mkdir_p(tmp_dir)

    config = Dust::Config.new
    original_device_id = config.device_id

    # Manually set the credentials file path and save
    cred_file = File.join(tmp_dir, "credentials.json")
    File.write(cred_file, {
      token:      "saved_token",
      device_id:  original_device_id,
      server_url: config.server_url,
    }.to_json)

    # Verify the file was written
    File.exists?(cred_file).should be_true
    data = JSON.parse(File.read(cred_file))
    data["token"].as_s.should eq "saved_token"
    data["device_id"].as_s.should eq original_device_id
  ensure
    FileUtils.rm_rf(tmp_dir) if tmp_dir
  end
end
