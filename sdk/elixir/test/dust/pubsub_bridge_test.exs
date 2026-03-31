defmodule Dust.PubSubBridgeTest do
  use ExUnit.Case

  defmodule BridgeDust do
    use Dust, otp_app: :dust_pubsub_test
  end

  setup do
    # Start Phoenix.PubSub for testing
    start_supervised!({Phoenix.PubSub, name: Dust.TestPubSub})

    Application.put_env(:dust_pubsub_test, BridgeDust,
      stores: ["test/store"],
      testing: :manual,
      pubsub: Dust.TestPubSub
    )

    start_supervised!(BridgeDust)
    :ok
  end

  test "events broadcast to PubSub topic" do
    Phoenix.PubSub.subscribe(Dust.TestPubSub, "dust:test/store")

    Dust.Testing.emit("test/store", "posts.hello",
      op: :set,
      value: %{"title" => "Hello"}
    )

    assert_receive {:dust_event, event}, 500
    assert event.path == "posts.hello"
    assert event.value == %{"title" => "Hello"}
  end

  test "events from put also broadcast" do
    Phoenix.PubSub.subscribe(Dust.TestPubSub, "dust:test/store")

    BridgeDust.put("test/store", "key", "value")

    assert_receive {:dust_event, event}, 500
    assert event.path == "key"
    assert event.value == "value"
  end

  test "unsubscribed processes do not receive events" do
    # Don't subscribe — just emit and verify nothing arrives
    Dust.Testing.emit("test/store", "posts.hello",
      op: :set,
      value: "val"
    )

    refute_receive {:dust_event, _}, 100
  end
end
