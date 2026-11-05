import Config

config :ash, default_string_length_count: :codepoints

config :mana_web, ManaWebTest.Endpoint,
  secret_key_base: String.duplicate("mana-web-test-secret-", 4),
  live_view: [signing_salt: "mana-web-test-live"],
  server: false

config :logger, level: :warning
