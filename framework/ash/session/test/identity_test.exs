defmodule Mana.Session.IdentityTest do
  use ExUnit.Case, async: true

  import SessionTest.Http

  alias AshAuthentication.TokenResource.Actions
  alias Mana.Session.Identity
  alias SessionTest.{ConfirmedUser, User}

  defp refused?(conn) do
    conn.halted and conn.status == 401 and body(conn) == %{"error" => "unauthenticated"} and
      Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
  end

  defp with_authorization(values) do
    conn = request(:get, "/auth/session")
    %{conn | req_headers: Enum.map(values, &{"authorization", &1}) ++ conn.req_headers}
  end

  test "refuses a missing, repeated, non-Bearer, empty or oversized credential" do
    for values <- [
          [],
          ["Bearer a", "Bearer b"],
          ["Basic dXNlcjpwYXNz"],
          ["bearer abc"],
          ["Bearer "],
          ["Bearer " <> String.duplicate("a", 8192)],
          ["Bearer not-a-jwt"]
        ] do
      assert values |> with_authorization() |> identity() |> refused?(), inspect(values)
    end
  end

  test "resolves nothing for a resource the app does not authenticate" do
    assert Identity.resolve("any", otp_app: :another_app, user: User) ==
             {:error, :unauthenticated}
  end

  describe "with stored tokens" do
    @describetag :postgres

    test "sets the actor and the token it was given" do
      {email, %{"accessToken" => token}} = sign_up()

      conn = request(:get, "/auth/session", nil, token) |> identity()

      refute conn.halted
      assert conn.assigns.access_token == token
      assert to_string(Ash.PlugHelpers.get_actor(conn).email) == email
    end

    test "refuses a valid token of another authenticated resource" do
      {_, %{"accessToken" => token}} = sign_up()

      assert request(:get, "/auth/session", nil, token) |> identity(ConfirmedUser) |> refused?()

      assert Identity.resolve(token, otp_app: :mana_session, user: ConfirmedUser) ==
               {:error, :unauthenticated}
    end

    test "refuses a token issued before its account was confirmed" do
      user = unconfirmed()
      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

      assert request(:get, "/auth/session", nil, token) |> identity(ConfirmedUser) |> refused?()
    end

    test "refuses a token that is no longer stored" do
      {_, %{"accessToken" => token}} = sign_up()
      :ok = Actions.revoke(SessionTest.Token, token)

      assert request(:get, "/auth/session", nil, token) |> identity() |> refused?()
    end
  end
end
