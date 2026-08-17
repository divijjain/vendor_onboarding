defmodule DocumentComplianceEngine.Storage.LocalDisk do
  @behaviour DocumentComplianceEngine.Storage

  @impl true
  def store(path, content) do
    # Absolute, since `document_paths` is later re-read by a different
    # process (an Oban job, or this same read/1) with its own cwd.
    full_path = upload_dir() |> Path.join(path) |> Path.expand()
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    {:ok, full_path}
  end

  @impl true
  def read(path), do: File.read(path)

  defp upload_dir do
    Application.get_env(:document_compliance_engine, :storage_upload_dir, "priv/uploads")
  end
end
