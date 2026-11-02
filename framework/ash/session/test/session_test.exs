defmodule Mana.SessionTest do
  use ExUnit.Case, async: true

  import SessionTest.Http

  alias SessionTest.ConfirmedUser

  test "init refuses an action the transport does not have" do
    assert_raise ArgumentError, ~r/Unknown session action/, fn ->
      Mana.Session.init(action: :refresh, user: SessionTest.User, token: SessionTest.Token)
    end
  end

  describe "input refused before AshAuthentication" do
    test "sign-up without a confirmation, with an oversized email or password is 422" do
      long = String.duplicate("a", 255)

      for body <- [
            %{"email" => email(), "password" => password()},
            %{"email" => long, "password" => password(), "passwordConfirmation" => password()},
            %{
              "email" => email(),
              "password" => String.duplicate("é", 37),
              "passwordConfirmation" => password()
            },
            %{"email" => 1, "password" => password(), "passwordConfirmation" => password()}
          ] do
        conn = request(:post, "/auth/sign-up", body) |> session(:sign_up)
        assert conn.status == 422
        assert body(conn) == %{"error" => "registration_rejected"}
        assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]

        assert Plug.Conn.get_resp_header(conn, "content-type") == [
                 "application/json; charset=utf-8"
               ]
      end
    end

    test "sign-in with missing, non-text or oversized credentials is 401" do
      for body <- [
            %{"email" => email()},
            %{"email" => [email()], "password" => password()},
            %{"email" => email(), "password" => String.duplicate("x", 73)}
          ] do
        conn = request(:post, "/auth/sign-in", body) |> session(:sign_in)
        assert conn.status == 401
        assert body(conn) == %{"error" => "invalid_credentials"}
      end
    end
  end

  describe "sessions" do
    @describetag :postgres

    test "sign-up trims the email and opens a session whose expiry is the token's" do
      email = email()
      {_, session} = sign_up("  " <> email <> " ")

      assert %{"accessToken" => token, "userId" => _, "email" => ^email, "expiresAt" => expires} =
               session

      {:ok, claims} = AshAuthentication.Jwt.peek(token)
      assert expires == claims["exp"] |> DateTime.from_unix!() |> DateTime.to_iso8601()
    end

    test "sign-up with a taken email is 422" do
      {email, _} = sign_up()

      conn =
        request(:post, "/auth/sign-up", %{
          "email" => email,
          "password" => password(),
          "passwordConfirmation" => password()
        })
        |> session(:sign_up)

      assert conn.status == 422
      assert body(conn) == %{"error" => "registration_rejected"}
    end

    test "sign-in answers the same 401 for a wrong password and an unknown account" do
      {email, %{"userId" => id}} = sign_up()

      assert %{status: 200} = conn = sign_in(email)
      assert %{"userId" => ^id, "email" => ^email, "accessToken" => _} = body(conn)

      for conn <- [sign_in(email, "not the password"), sign_in(email())] do
        assert conn.status == 401
        assert body(conn) == %{"error" => "invalid_credentials"}
      end
    end

    test "show answers the identity without issuing a token" do
      {email, %{"accessToken" => token, "expiresAt" => expires}} = sign_up()

      conn = request(:get, "/auth/session", nil, token) |> identity() |> session(:show)

      assert conn.status == 200
      assert %{"email" => ^email, "expiresAt" => ^expires} = body = body(conn)
      refute Map.has_key?(body, "accessToken")
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "sign-out revokes the Bearer it was called with, and only that one" do
      {email, %{"accessToken" => token}} = sign_up()
      %{"accessToken" => other} = body(sign_in(email))

      conn = request(:delete, "/auth/session", nil, token) |> identity() |> session(:sign_out)
      assert conn.status == 204
      assert conn.resp_body == ""

      assert request(:get, "/auth/session", nil, token) |> identity() |> Map.get(:status) == 401
      refute request(:get, "/auth/session", nil, other) |> identity() |> Map.get(:halted)
    end

    test "with confirmation, sign-up answers 202 without a session and sign-in waits" do
      email = email()

      conn =
        request(:post, "/auth/sign-up", %{
          "email" => email,
          "password" => password(),
          "passwordConfirmation" => password()
        })
        |> run(Mana.Session,
          action: :sign_up,
          user: ConfirmedUser,
          token: SessionTest.Token,
          confirmation: true
        )

      assert conn.status == 202
      assert body(conn) == %{"status" => "confirmation_required"}
      assert_received {:confirm, ^email, _token}
      assert sign_in(email, password(), ConfirmedUser).status == 401
    end
  end
end
