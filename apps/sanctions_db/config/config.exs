import Config

config :sanctions_db, port: 8011

import_config "#{config_env()}.exs"
