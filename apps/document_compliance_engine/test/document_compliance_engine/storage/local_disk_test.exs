defmodule DocumentComplianceEngine.Storage.LocalDiskTest do
  use ExUnit.Case, async: true

  alias DocumentComplianceEngine.Storage

  test "store/2 writes content to disk under the configured upload dir and returns the path" do
    path = "test-#{System.unique_integer([:positive])}/contract.pdf"

    assert {:ok, full_path} = Storage.store(path, "pdf-bytes")
    assert File.read!(full_path) == "pdf-bytes"

    on_exit(fn -> File.rm_rf(Path.dirname(full_path)) end)
  end

  test "read/1 reads back exactly what store/2 wrote" do
    path = "test-#{System.unique_integer([:positive])}/contract.pdf"
    {:ok, full_path} = Storage.store(path, "pdf-bytes")

    assert Storage.read(full_path) == {:ok, "pdf-bytes"}

    on_exit(fn -> File.rm_rf(Path.dirname(full_path)) end)
  end

  test "read/1 returns an error for a path that doesn't exist" do
    assert {:error, :enoent} = Storage.read("/nonexistent/path.pdf")
  end
end
