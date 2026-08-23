defmodule DocumentComplianceEngineWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DocumentComplianceEngineWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint DocumentComplianceEngineWeb.Endpoint

      use DocumentComplianceEngineWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import DocumentComplianceEngineWeb.ConnCase
    end
  end

  setup tags do
    DocumentComplianceEngine.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Signs a raw webhook body the same way `VerifyWebhookSignature` expects,
  using the fixed `:webhook_secret` configured in `config/test.exs`.
  """
  def sign_webhook_body(raw_body) do
    secret = Application.fetch_env!(:document_compliance_engine, :webhook_secret)
    hex = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)
    "sha256=" <> hex
  end

  @doc """
  Puts a real, signed session on `conn` for `user`, the same way
  `UserAuth.log_in_user/2` does — for driving an authenticated
  `live(conn, ~p"/...")` call against a route behind
  `:require_authenticated_user`.
  """
  def log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end
end
