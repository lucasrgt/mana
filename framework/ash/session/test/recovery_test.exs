defmodule Mana.Session.RecoveryTest do
  use ExUnit.Case, async: true

  import SessionTest.Http

  alias AshAuthentication.Strategy.Password
  alias Mana.Session.{PasswordReset, Recovery}
  alias SessionTest.{ConfirmedUser, User}

  def enqueue(email) do
    send(self(), {:enqueued, email})
    Process.get(:enqueue, :ok)
  end

  defp ask(body),
    do:
      request(:post, "/auth/request-password-reset", body)
      |> run(Recovery, action: :request, enqueue: {__MODULE__, :enqueue})

  defp reset(token, password \\ "a brand new password", confirmation \\ nil),
    do:
      request(:post, "/auth/reset-password", %{
        "token" => token,
        "password" => password,
        "passwordConfirmation" => confirmation || password
      })
      |> run(Recovery, action: :reset, user: User)

  defp reset_token(email, resource \\ User) do
    strategy = AshAuthentication.Info.strategy!(resource, :password)
    :ok = AshAuthentication.Strategy.action(strategy, :reset_request, %{"email" => email})
    assert_received {:reset, ^email, token}
    token
  end

  defp signed_in?(token), do: not (request(:get, "/", nil, token) |> identity()).halted

  describe "request" do
    test "enqueues the trimmed email and answers 202 whether or not it has an account" do
      conn = ask(%{"email" => "  nobody@example.test "})

      assert conn.status == 202
      assert body(conn) == %{"status" => "accepted"}
      assert_received {:enqueued, "nobody@example.test"}
    end

    test "a delivery that cannot be queued is 503" do
      Process.put(:enqueue, {:error, :unavailable})
      conn = ask(%{"email" => "nobody@example.test"})

      assert conn.status == 503
      assert body(conn) == %{"error" => "recovery_unavailable"}
    end

    test "an invalid email is 422 and nothing is queued" do
      for body <- [
            %{},
            %{"email" => "no-at-sign"},
            %{"email" => "two words@example.test"},
            %{"email" => 3},
            %{"email" => String.duplicate("a", 250) <> "@x.io"}
          ] do
        conn = ask(body)
        assert conn.status == 422
        assert body(conn) == %{"error" => "invalid_request"}
      end

      refute_received {:enqueued, _}
    end
  end

  describe "reset input" do
    test "a missing, empty or oversized field is 422 before any token is read" do
      for {token, password} <- [
            {"", "a brand new password"},
            {String.duplicate("t", 8192), "a brand new password"},
            {"token", String.duplicate("p", 73)}
          ] do
        conn = reset(token, password)
        assert conn.status == 422
        assert body(conn) == %{"error" => "reset_rejected"}
      end

      conn =
        request(:post, "/auth/reset-password", %{"token" => "t"})
        |> run(Recovery, action: :reset, user: User)

      assert conn.status == 422
    end
  end

  describe "reset" do
    @describetag :postgres

    test "changes the password, revokes every session and issues none" do
      {email, %{"accessToken" => first}} = sign_up()
      %{"accessToken" => second} = body(sign_in(email))

      conn = reset(reset_token(email))

      assert conn.status == 204
      assert conn.resp_body == ""
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      refute signed_in?(first)
      refute signed_in?(second)
      assert sign_in(email).status == 401
      assert sign_in(email, "a brand new password").status == 200
    end

    test "a used token is refused" do
      {email, _} = sign_up()
      token = reset_token(email)

      assert reset(token).status == 204
      assert %{status: 422} = conn = reset(token, "yet another password")
      assert body(conn) == %{"error" => "reset_rejected"}
      assert sign_in(email, "a brand new password").status == 200
    end

    test "a refused password changes nothing and leaves the token usable" do
      {email, %{"accessToken" => session}} = sign_up()
      token = reset_token(email)

      assert reset(token, "a brand new password", "a different one").status == 422
      assert signed_in?(session)
      assert sign_in(email).status == 200
      assert reset(token).status == 204
    end

    test "a token of another resource or purpose is refused" do
      {email, %{"accessToken" => session}} = sign_up()
      user = unconfirmed(email)
      strategy = AshAuthentication.Info.strategy!(ConfirmedUser, :password)
      {:ok, foreign} = Password.reset_token_for(strategy, user)

      assert reset(foreign).status == 422
      assert reset(session).status == 422
      assert sign_in(email).status == 200
    end

    test "two resets racing on one token: exactly one wins" do
      {email, _} = sign_up()
      token = reset_token(email)

      params = fn password ->
        %{"reset_token" => token, "password" => password, "password_confirmation" => password}
      end

      results =
        ["first new password", "second new password"]
        |> Enum.map(fn password ->
          Task.async(fn -> {password, PasswordReset.reset(User, params.(password))} end)
        end)
        |> Task.await_many(30_000)

      assert [{winner, :ok}] = Enum.filter(results, &match?({_, :ok}, &1))
      assert [{_, {:error, :reset_rejected}}] = results -- [{winner, :ok}]
      assert sign_in(email, winner).status == 200
    end
  end
end
