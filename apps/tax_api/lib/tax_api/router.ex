defmodule TaxApi.Router do
  @moduledoc false

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  forward("/mcp",
    to: Hermes.Server.Transport.StreamableHTTP.Plug,
    init_opts: [server: TaxApi.Server]
  )

  match _ do
    send_resp(conn, 404, "not found")
  end
end
