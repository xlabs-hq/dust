defmodule Dust.Webhooks.DeliveryWorkerTest do
  use Dust.DataCase, async: false

  alias Dust.Webhooks.DeliveryWorker

  test "sign produces correct HMAC-SHA256" do
    body = ~s({"event":"ping"})
    secret = "whsec_test_secret"

    signature = DeliveryWorker.sign(body, secret)

    # Verify it's a valid hex string
    assert String.length(signature) == 64
    assert Regex.match?(~r/^[0-9a-f]+$/, signature)

    # Verify deterministic
    assert DeliveryWorker.sign(body, secret) == signature

    # Verify different secret produces different signature
    refute DeliveryWorker.sign(body, "whsec_other") == signature
  end

  test "sign matches expected HMAC-SHA256 computation" do
    body = "test"
    secret = "secret"
    expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
    assert DeliveryWorker.sign(body, secret) == expected
  end

  test "backoff returns escalating delays" do
    assert DeliveryWorker.backoff(%Oban.Job{attempt: 1}) == 60
    assert DeliveryWorker.backoff(%Oban.Job{attempt: 2}) == 300
    assert DeliveryWorker.backoff(%Oban.Job{attempt: 3}) == 1800
    assert DeliveryWorker.backoff(%Oban.Job{attempt: 4}) == 7200
    assert DeliveryWorker.backoff(%Oban.Job{attempt: 5}) == 43200
  end

  test "backoff defaults to 43200 for attempts beyond 5" do
    assert DeliveryWorker.backoff(%Oban.Job{attempt: 6}) == 43200
    assert DeliveryWorker.backoff(%Oban.Job{attempt: 10}) == 43200
  end
end
