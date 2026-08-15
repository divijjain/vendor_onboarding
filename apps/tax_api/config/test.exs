import Config

# The tool rule is tested as a pure function — no need to bind a port.
config :tax_api, port: nil

config :logger, level: :warning
