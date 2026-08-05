defmodule VendorOnboarding.Storage.LocalDisk do
  @behaviour VendorOnboarding.Storage

  @impl true
  def store(path, content) do
    full_path = Path.join(upload_dir(), path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    {:ok, full_path}
  end

  defp upload_dir do
    Application.get_env(:vendor_onboarding, :storage_upload_dir, "priv/uploads")
  end
end
