defmodule Mana.Session.ConfirmationTest do
  use ExUnit.Case, async: true

  import SessionTest.Http

  alias AshAuthentication.Strategy.Password
  alias Mana.Session.Confirmation
  alias SessionTest.ConfirmedUser

  def enqueue(email) do
    send(self(), {:enqueued, email})
    Process.get(:enqueue, :ok)
  end

  defp ask(body),
    do:
      request(:post, "/auth/request-confirmation", body)
      |> run(Confirmation, action: :request, enqueue: {__MODULE__, :enqueue})

  defp confirm(body),
    do:
      request(:post, "/auth/confirm-email", body)
      |> run(Confirmation, action: :confirm, user: ConfirmedUser, strategy: :confirm_new_user)

  defp signed_in?(token),
    do: not (request(:get, "/", nil, token) |> identity(ConfirmedUser)).halted

  defp registered do
    email = email()
    user = unconfirmed(email)
    assert_received {:confirm, ^email, token}
    {user, token}
  end

  describe "request" do
    test "enqueues the trimmed email and answers a generic 202" do
      conn = ask(%{"email" => " someone@example.test  "})

      assert conn.status == 202
      assert body(conn) == %{"status" => "accepted"}
      assert_received {:enqueued, "someone@example.test"}
    end

    test "a delivery that cannot be queued is 503" do
      Process.put(:enqueue, :error)
      assert %{status: 503} = conn = ask(%{"email" => "someone@example.test"})
      assert body(conn) == %{"error" => "confirmation_unavailable"}
    end

    test "an invalid email is 422 and nothing is queued" do
      for body <- [%{}, %{"email" => "nope"}, %{"email" => "a b@c.d"}, %{"email" => nil}] do
        assert %{status: 422} = conn = ask(body)
        assert body(conn) == %{"error" => "invalid_request"}
      end

      refute_received {:enqueued, _}
    end
  end

  test "confirm refuses a missing, empty or oversized token before reading it" do
    for body <- [
          %{},
          %{"token" => ""},
          %{"token" => String.duplicate("t", 8192)},
          %{"token" => 1}
        ] do
      assert %{status: 422} = conn = confirm(body)
      assert body(conn) == %{"error" => "confirmation_rejected"}
    end
  end

  describe "confirm" do
    @describetag :postgres

    test "confirms without signing in; sign-in works afterwards" do
      {user, token} = registered()
      email = to_string(user.email)
      assert sign_in(email, password(), ConfirmedUser).status == 401

      conn = confirm(%{"token" => token})

      assert conn.status == 204
      assert conn.resp_body == ""
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      assert %{status: 200} = signed = sign_in(email, password(), ConfirmedUser)
      assert signed_in?(body(signed)["accessToken"])
    end

    test "a token is confirmed once; replay is refused" do
      {_, token} = registered()

      assert confirm(%{"token" => token}).status == 204
      assert confirm(%{"token" => token}).status == 422
    end

    test "confirming revokes the tokens issued before it" do
      {user, token} = registered()
      {:ok, earlier, _} = AshAuthentication.Jwt.token_for_user(user)

      assert confirm(%{"token" => token}).status == 204
      refute signed_in?(earlier)
    end

    test "a token of another purpose is refused" do
      {user, _} = registered()
      strategy = AshAuthentication.Info.strategy!(ConfirmedUser, :password)
      {:ok, reset} = Password.reset_token_for(strategy, user)
      {:ok, session, _} = AshAuthentication.Jwt.token_for_user(user)

      assert confirm(%{"token" => reset}).status == 422
      assert confirm(%{"token" => session}).status == 422
    end
  end
end
