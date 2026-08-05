defmodule VendorOnboarding.IdempotencyTest do
  use ExUnit.Case, async: true

  alias VendorOnboarding.Idempotency

  test "hash/1 is deterministic for identical payloads" do
    payload = ~s({"contract":"abc","w9":"def"})
    assert Idempotency.hash(payload) == Idempotency.hash(payload)
  end

  test "hash/1 differs for different payloads" do
    refute Idempotency.hash("payload-a") == Idempotency.hash("payload-b")
  end

  test "hash/1 returns a lowercase hex string" do
    hash = Idempotency.hash("payload")
    assert hash =~ ~r/^[0-9a-f]{64}$/
  end
end
