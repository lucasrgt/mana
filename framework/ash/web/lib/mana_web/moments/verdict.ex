defmodule ManaWeb.Moments.Verdict do
  @moduledoc """
  The AVP (Acceptance Verification Protocol) verdict of a Moment's criteria, the
  same one the Dart runner gives (its `avpVerdict`):
  unavailable evidence is `unresolved`, never `pass`, and a run-level failure no
  criterion carries becomes a result of its own, so the verdict is never greener
  than the report. Both runners are held to `framework/contracts/avp-verdicts.json`.
  """

  @protocol_version "0.4.0"
  @archetype "moment-criteria"

  @doc """
  The verdict of `checks`, the evaluated criteria of a report whose overall
  `status` is `"passed"`, `"failed"` or `"unavailable"`.
  """
  def avp(subject, status, checks, reason \\ nil) do
    results = checks |> Enum.map(&result/1) |> run_level(status, reason)
    passed = Enum.count(results, &(&1["status"] == "pass"))
    failed = Enum.count(results, &(&1["status"] == "fail"))
    applicable = passed + failed

    %{
      "protocol" => "avp",
      "protocolVersion" => @protocol_version,
      "subject" => subject,
      "archetype" => @archetype,
      "results" => results,
      "outcome" =>
        outcome(failed, applicable, Enum.any?(results, &(&1["status"] == "unresolved"))),
      "acceptanceScore" => if(applicable == 0, do: nil, else: passed / applicable)
    }
  end

  defp run_level(results, status, reason) do
    statuses = MapSet.new(results, & &1["status"])

    cond do
      status == "failed" and "fail" not in statuses ->
        results ++
          [
            %{
              "criterionId" => "moment-run",
              "status" => "fail",
              "reason" => reason || "The journey failed"
            }
          ]

      status not in ["passed", "failed"] and "unresolved" not in statuses ->
        observation = %{
          "criterionId" => "moment-observation",
          "status" => "unresolved",
          "reason" => reason || "The Moment could not be observed"
        }

        results ++ [observation]

      true ->
        results
    end
  end

  defp outcome(failed, _applicable, _unresolved?) when failed > 0, do: "fail"
  defp outcome(_failed, 0, _unresolved?), do: "inconclusive"
  defp outcome(_failed, _applicable, true), do: "inconclusive"
  defp outcome(_failed, _applicable, false), do: "pass"

  defp result(check) do
    evidence =
      if Map.has_key?(check, "expected") or Map.has_key?(check, "observed") do
        present(%{
          "field" => check["field"],
          "expected" => check["expected"],
          "observed" => check["observed"]
        })
      end

    present(%{
      "criterionId" => check["name"],
      "status" => status(check["status"]),
      "reason" => check["reason"] || failure(check),
      "evidence" => evidence
    })
  end

  defp status("passed"), do: "pass"
  defp status("failed"), do: "fail"
  defp status("not-applicable"), do: "not-applicable"
  defp status(_status), do: "unresolved"

  defp failure(%{"status" => "failed", "field" => nil} = check),
    do: "Criterion #{check["name"]} did not hold"

  defp failure(%{"status" => "failed", "field" => field} = check),
    do: "#{field}: expected #{dart(check["expected"])}, observed #{dart(check["observed"])}"

  defp failure(%{"status" => "failed"} = check), do: "Criterion #{check["name"]} did not hold"
  defp failure(_check), do: nil

  # How Dart's string interpolation writes a JSON value, so both runners give the same reason.
  defp dart(nil), do: "null"

  defp dart(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  defp dart(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &dart/1) <> "]"

  defp dart(value) when is_map(value),
    do: "{" <> Enum.map_join(value, ", ", fn {k, v} -> "#{k}: #{dart(v)}" end) <> "}"

  # Dart's `'key': ?value` leaves the key out when the value is null.
  defp present(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
