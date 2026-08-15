import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :vendor_onboarding, VendorOnboarding.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "vendor_onboarding_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Test-only Cloak key for encrypting Tax ID at rest.
config :vendor_onboarding, VendorOnboarding.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("rKkltynnd1GqMDbqeWXUkZw1wveyaBvGWzpRN5d8NKU="),
       iv_length: 12}
  ]

# Fixed test webhook secret — request signing helper lives in
# VendorOnboardingWeb.ConnCase.
config :vendor_onboarding, :webhook_secret, "test-only-webhook-secret"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :vendor_onboarding, VendorOnboardingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YNpmY74345BmESa513Ddw0g2QODG+RfnccMKlnonm+DqdRgC/N68mcLaAvZOZ5Mb",
  server: false

# In test we don't send emails
config :vendor_onboarding, VendorOnboarding.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Keep test-generated documents out of priv/uploads entirely.
config :vendor_onboarding,
       :storage_upload_dir,
       Path.join(System.tmp_dir!(), "vendor_onboarding_test_uploads")

# Don't actually run jobs in the test suite — assert on enqueueing instead.
config :vendor_onboarding, Oban, testing: :manual

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
