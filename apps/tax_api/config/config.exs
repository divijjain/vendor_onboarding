import Config

config :tax_api, port: 8010

import_config "#{config_env()}.exs"
