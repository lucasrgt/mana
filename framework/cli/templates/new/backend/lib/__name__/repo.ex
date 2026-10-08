defmodule __Name__.Repo do
  use AshPostgres.Repo, otp_app: :__name__

  def installed_extensions, do: ["ash-functions"]
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
