import Config

config :ash, default_string_length_count: :codepoints
config :bcrypt_elixir, log_rounds: 4
config :logger, level: :warning

config :mana_session,
  ash_domains: [SessionTest.Accounts],
  token_signing_secret: "session-test-signing-secret-of-at-least-32-bytes",
  web_origin: "http://app.test"
