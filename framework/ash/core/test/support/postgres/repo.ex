defmodule PostgresTest.Repo do
  @moduledoc false
  # The harness creates its tables by hand (migrations/), not with the
  # migration generator, so Ash's SQL functions are not installed and no
  # harness action may rely on them.
  use AshPostgres.Repo, otp_app: :mana_core, warn_on_missing_ash_functions?: false

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
