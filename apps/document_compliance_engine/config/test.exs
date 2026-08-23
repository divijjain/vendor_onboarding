import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :document_compliance_engine, DocumentComplianceEngine.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "document_compliance_engine_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Test-only Cloak key for encrypting Tax ID at rest.
config :document_compliance_engine, DocumentComplianceEngine.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("rKkltynnd1GqMDbqeWXUkZw1wveyaBvGWzpRN5d8NKU="),
       iv_length: 12}
  ]

# Fixed test webhook secret — request signing helper lives in
# DocumentComplianceEngineWeb.ConnCase.
config :document_compliance_engine, :webhook_secret, "test-only-webhook-secret"

# Tests never drive a real Google OAuth2 handshake — they set
# conn.assigns.ueberauth_auth directly — but Ueberauth.Strategy.Google.OAuth
# still needs *some* configured value to exist.
config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: "test-client-id",
  client_secret: "test-client-secret"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :document_compliance_engine, DocumentComplianceEngineWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YNpmY74345BmESa513Ddw0g2QODG+RfnccMKlnonm+DqdRgC/N68mcLaAvZOZ5Mb",
  server: false

# In test we don't send emails
config :document_compliance_engine, DocumentComplianceEngine.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Keep test-generated documents out of priv/uploads entirely.
config :document_compliance_engine,
       :storage_upload_dir,
       Path.join(System.tmp_dir!(), "document_compliance_engine_test_uploads")

# `:storage_adapter` is left unset (defaults to `LocalDisk`, see
# `storage.ex`) — this only configures `Storage.S3` itself for its own
# direct unit tests (`storage/s3_test.exs`), which stub the HTTP layer via
# `Req.Test` rather than hitting real S3/Tigris.
config :document_compliance_engine, :s3,
  bucket: "test-bucket",
  region: "auto",
  endpoint: "https://fly.storage.tigris.dev",
  access_key_id: "test-access-key-id",
  secret_access_key: "test-secret-access-key"

# Don't actually run jobs in the test suite — assert on enqueueing instead.
config :document_compliance_engine, Oban, testing: :manual

# Deterministic by default — tests that care about audit sampling set this
# to 1.0 for the duration of that test (see MaybeSampleForAudit's moduledoc).
config :document_compliance_engine, :audit_sample_rate, 0.0

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
