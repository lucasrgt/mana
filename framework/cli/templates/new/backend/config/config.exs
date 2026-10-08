import Config

config :ash, default_string_length_count: :codepoints

config :__name__,
  moment_recipes?: config_env() == :dev,
  ecto_repos: [__Name__.Repo],
  ash_domains: [__Name__.Notes]

config :phoenix, :json_library, Jason

config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :__name__, __Name__Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: __Name__.PubSub,
  url: [host: "localhost"]

config :logger, level: :warning
