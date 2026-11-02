defmodule ManaLint.Check.PersistentTermHotWriteTest do
  use Credo.Test.Case

  alias ManaLint.Check.PersistentTermHotWrite, as: Check

  test "a value stored with its time, and a TTL-guarded refresh" do
    """
    defmodule App.Knobs do
      def get(key, ttl) do
        now = System.monotonic_time(:millisecond)

        case :persistent_term.get(key, nil) do
          {value, at} when now - at < ttl -> value
          _ ->
            value = load(key)
            :persistent_term.put(key, {value, now})
            value
        end
      end

      def keys(now) do
        if stale?(), do: :persistent_term.put(__MODULE__, :refreshing)
        :persistent_term.put(__MODULE__, {now + 3600, fetch()})
      end

      defp expired?(at), do: at < DateTime.utc_now()

      def certs(at) do
        if expired?(at), do: :persistent_term.put(:certs, fetch())
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issues(&assert(length(&1) == 3))
  end

  test "init-time and lazy-once puts are fine" do
    """
    defmodule App.Routes do
      def load(rules), do: :persistent_term.put(:rules, Enum.map(rules, &parse/1))

      def routes do
        case :persistent_term.get(__MODULE__, nil) do
          nil ->
            routes = build()
            :persistent_term.put(__MODULE__, routes)
            routes

          routes ->
            routes
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end
end
