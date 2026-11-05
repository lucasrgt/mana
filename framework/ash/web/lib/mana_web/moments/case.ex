defmodule ManaWeb.Moments.Case do
  @moduledoc """
  Every web Moment of an app as an ExUnit test, judged by `ManaWeb.Moments`:

      defmodule MyAppWeb.MomentsTest do
        use MyAppWeb.ConnCase, async: false

        use ManaWeb.Moments.Case,
          domain: MyApp.Agencies,
          endpoint: MyAppWeb.Endpoint,
          recipes: MyApp.Moments.Agencies.__recipes__(),
          sign_in: &__MODULE__.sign_in/2

        def sign_in(conn, account), do: ...
      end

  `domain:` is the domain whose `moments` section names the app (its
  `Moments.Manifest.build/2`); `manifest:` takes a built manifest instead. A test
  passes only on a `pass` verdict: a failed criterion fails it, and so does
  unavailable evidence, with the report's reason. The test's `conn`, when the case
  template gives one, is where the Moment starts.

  Run them without the database's async sandbox (`async: false`): the LiveView
  runs in a process of its own and reads what the recipe wrote.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts, runner: __MODULE__] do
      @mana_moments_runner runner
      @mana_moments_manifest opts[:manifest] ||
                               Moments.Manifest.build(Keyword.fetch!(opts, :domain))
      @mana_moments_opts Keyword.drop(opts, [:manifest, :domain])

      for {name, description} <- runner.web_moments(@mana_moments_manifest) do
        @mana_moment name
        test "moment:#{name} #{description}", context do
          @mana_moments_runner.run!(
            @mana_moments_manifest,
            @mana_moment,
            @mana_moments_opts,
            context
          )
        end
      end
    end
  end

  @doc false
  def web_moments(manifest) do
    for {name, moment} <- Enum.sort(manifest["moments"]),
        ManaWeb.Moments.web?(moment),
        do: {name, moment["description"]}
  end

  @doc false
  def run!(manifest, name, opts, context) do
    opts = if conn = context[:conn], do: Keyword.put_new(opts, :conn, conn), else: opts
    assert_pass(ManaWeb.Moments.run(manifest, name, opts))
  end

  @doc "Fails unless `report`'s verdict is `pass`, telling each criterion that did not hold and why."
  def assert_pass(%{"verdict" => %{"outcome" => "pass"}} = report), do: report

  def assert_pass(report) do
    lines =
      for result <- report["verdict"]["results"], result["status"] != "pass" do
        "  #{result["status"]} #{result["criterionId"]}: #{result["reason"]}"
      end

    steps =
      for step <- report["steps"],
          step["status"] != "done",
          do: "  step #{step["name"]} #{step["status"]}: #{step["reason"]}"

    ExUnit.Assertions.flunk(
      "moment:#{report["moment"]} is #{report["verdict"]["outcome"]}\n" <>
        Enum.join(lines ++ steps, "\n")
    )
  end
end
