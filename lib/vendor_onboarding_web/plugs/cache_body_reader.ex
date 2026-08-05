defmodule VendorOnboardingWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Plug.Parsers `:body_reader` override that stashes the raw request body on
  `conn.assigns.raw_body` before parsing consumes it. The webhook idempotency
  key is a hash of these exact bytes, not the re-serialized parsed params.
  """

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
  end
end
