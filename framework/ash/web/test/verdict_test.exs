defmodule ManaWeb.Moments.VerdictTest do
  # The Dart runner is held to the same cases, in its verdict parity test.
  use ExUnit.Case, async: true

  alias ManaWeb.Moments.Verdict

  @cases Path.expand("../../../contracts/moments/avp-verdicts.json", __DIR__)
         |> File.read!()
         |> Jason.decode!()

  for c <- @cases do
    @case c
    test "AVP verdict: #{c["case"]}" do
      verdict = Verdict.avp(@case["subject"], @case["status"], @case["checks"], @case["reason"])
      assert verdict |> Jason.encode!() |> Jason.decode!() == @case["verdict"]
    end
  end
end
