import Config

# Locally the backend runs through `mana lab`, which points it at a Moments
# sandbox's database (LAB_*); in production these come from the host.
if config_env() == :prod do
  config :__name__, __Name__.Repo, url: System.fetch_env!("DATABASE_URL"), pool_size: 10

  config :__name__, __Name__Web.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    server: true

  config :__name__, web_origins: String.split(System.get_env("WEB_ORIGINS", ""), ",", trim: true)
else
  config :__name__, __Name__.Repo,
    url: System.get_env("LAB_DATABASE_URL", "ecto://postgres:postgres@127.0.0.1/__name___dev"),
    pool_size: 5

  config :__name__, __Name__Web.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("LAB_PORT", "4000"))],
    secret_key_base: System.get_env("LAB_SECRET_KEY_BASE", String.duplicate("dev-only-secret-", 4)),
    server: System.get_env("LAB_SERVER") == "true"

  config :__name__,
    moments_recipe_token: System.get_env("MOMENTS_RECIPE_TOKEN"),
    web_origins: String.split(System.get_env("LAB_WEB_ORIGINS", ""), ",", trim: true)
end
