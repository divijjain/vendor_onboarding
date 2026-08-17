# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Loads apps/document_compliance_engine/.env or .envrc (whichever exists;
# .env checked first) into the process environment for local dev — see
# .env.example. Real API keys never get checked in; both filenames are
# gitignored. A var already exported in the shell always wins, so this is
# a no-op in CI/prod where secrets come from the real environment. Must
# run before anything below reads System.get_env/1 (the OPENAI_API_KEY
# config a few lines down), so it's here, not in runtime.exs.
env_file =
  Enum.find(["../.env", "../.envrc"], &File.exists?(Path.expand(&1, __DIR__)))

if env_file do
  Path.expand(env_file, __DIR__)
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.reject(&String.starts_with?(&1, "#"))
  |> Enum.each(fn line ->
    with [key, value] <- String.split(line, "=", parts: 2),
         key = String.trim(key),
         value = value |> String.trim() |> String.trim("\"") |> String.trim("'"),
         nil <- System.get_env(key) do
      System.put_env(key, value)
    end
  end)
end

config :document_compliance_engine,
  ecto_repos: [DocumentComplianceEngine.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :document_compliance_engine, DocumentComplianceEngineWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [
      html: DocumentComplianceEngineWeb.ErrorHTML,
      json: DocumentComplianceEngineWeb.ErrorJSON
    ],
    layout: false
  ],
  pubsub_server: DocumentComplianceEngine.PubSub,
  live_view: [signing_salt: "neaTq79t"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :document_compliance_engine, DocumentComplianceEngine.Mailer,
  adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  document_compliance_engine: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  document_compliance_engine: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :document_compliance_engine, :storage_upload_dir, "priv/uploads"

config :document_compliance_engine, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  repo: DocumentComplianceEngine.Repo,
  plugins: [Oban.Plugins.Pruner],
  queues: [agent_runs: 5]

config :instructor,
  adapter: Instructor.Adapters.OpenAI,
  openai: [api_key: System.get_env("OPENAI_API_KEY")]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
