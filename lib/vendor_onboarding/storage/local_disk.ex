defmodule VendorOnboarding.Storage.LocalDisk do
  @behaviour VendorOnboarding.Storage

  @impl true
  def store(path, content) do
    # Absolute, since the path is later read by the Python agent service —
    # a different process with a different cwd on the same local machine.
    full_path = upload_dir() |> Path.join(path) |> Path.expand()
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    {:ok, full_path}
  end

  defp upload_dir do
    Application.get_env(:vendor_onboarding, :storage_upload_dir, "priv/uploads")
  end
end
