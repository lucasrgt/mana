defmodule Mana.Session.ThrottleTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import SessionTest.Http

  alias Mana.Session.Throttle

  defmodule Limiter do
    @moduledoc "Reports each hit to the test and answers what the test put in its dictionary."
    def hit(key, window, budget) do
      send(self(), {:hit, key, window, budget})
      Process.get(:limiter, fn -> {:allow, 1} end).()
    end
  end

  defp throttle(conn, scope),
    do: run(conn, Throttle, scope: scope, otp_app: :mana_session, limiter: Limiter)

  defp answer(decision), do: Process.put(:limiter, decision)

  describe "by IP" do
    test "every credential route spends the IP's budget of 30 a minute" do
      for route <- [
            "sign-in",
            "sign-up",
            "request-password-reset",
            "reset-password",
            "request-confirmation",
            "confirm-email"
          ] do
        conn = request(:post, "/auth/" <> route) |> throttle(:ip)
        refute conn.halted
        assert_received {:hit, {:ip, {127, 0, 0, 1}}, 60_000, 30}
      end
    end

    test "other routes and methods pass without spending" do
      for {method, path} <- [
            {:get, "/auth/session"},
            {:get, "/auth/sign-in"},
            {:post, "/api/notes"}
          ] do
        refute (request(method, path) |> throttle(:ip)).halted
      end

      refute_received {:hit, _, _, _}
    end

    test "an exhausted budget answers 429 with whole seconds to wait, at least one" do
      for {milliseconds, seconds} <- [{1500, "2"}, {1000, "1"}, {0, "1"}] do
        answer(fn -> {:deny, milliseconds} end)
        conn = request(:post, "/auth/sign-in") |> throttle(:ip)

        assert conn.halted
        assert conn.status == 429
        assert get_resp_header(conn, "retry-after") == [seconds]
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert body(conn) == %{"error" => "rate_limited"}
      end
    end

    test "an unavailable counter answers 503, not admission" do
      for failure <- [fn -> raise ArgumentError end, fn -> exit(:noproc) end] do
        answer(failure)
        conn = request(:post, "/auth/sign-in") |> throttle(:ip)

        assert conn.halted
        assert conn.status == 503
        assert body(conn) == %{"error" => "sign_in_unavailable"}
      end
    end
  end

  describe "by account" do
    test "one budget of 6 per normalised email, keyed by an HMAC, never the email" do
      for email <- ["Person@Example.test", "  person@example.test "] do
        refute (request(:post, "/auth/sign-in", %{"email" => email}) |> throttle(:account)).halted
      end

      assert_received {:hit, {:account, digest}, 60_000, 6}
      assert_received {:hit, {:account, ^digest}, 60_000, 6}
      refute digest =~ "person"

      request(:post, "/auth/sign-in", %{"email" => "other@example.test"}) |> throttle(:account)
      assert_received {:hit, {:account, other}, _, _}
      refute other == digest
    end

    test "a request without a usable email is left to the route's own validation" do
      for body <- [%{}, %{"email" => 7}, %{"email" => String.duplicate("a", 255)}] do
        refute (request(:post, "/auth/sign-in", body) |> throttle(:account)).halted
      end

      refute_received {:hit, _, _, _}
    end
  end
end
