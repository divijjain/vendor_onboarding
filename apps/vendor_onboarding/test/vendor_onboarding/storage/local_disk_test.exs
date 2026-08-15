defmodule VendorOnboarding.Storage.LocalDiskTest do
  use ExUnit.Case, async: true

  alias VendorOnboarding.Storage

  test "store/2 writes content to disk under the configured upload dir and returns the path" do
    path = "test-#{System.unique_integer([:positive])}/contract.pdf"

    assert {:ok, full_path} = Storage.store(path, "pdf-bytes")
    assert File.read!(full_path) == "pdf-bytes"

    on_exit(fn -> File.rm_rf(Path.dirname(full_path)) end)
  end
end
