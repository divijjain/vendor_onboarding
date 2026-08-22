import Config

# Fly (and most PaaS targets) assign the listen port via PORT at container
# boot, not build time — config.exs's static `port: 8010` stays the local
# dev/test default; this only overrides it when the env var is actually set.
if port = System.get_env("PORT") do
  config :tax_api, port: String.to_integer(port)
end
