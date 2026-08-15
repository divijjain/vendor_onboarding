import Config

# The watchlist rule is tested as a pure function — no need to bind a port.
config :sanctions_db, port: nil

config :logger, level: :warning
