defmodule Mana.UpgradeTest do
  use ExUnit.Case, async: true

  alias Mana.Upgrade
  alias Mana.Upgrade.{Diff, TimedRules, VerbSteps}

  @fixtures Path.expand("fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "mana-upgrade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tmp_dir: dir}
  end

  # Copies the `.before` files of a fixture into `dir` as the app's sources.
  defp app(fixture, dir) do
    for before <- Path.wildcard(Path.join([@fixtures, fixture, "*.before"])) do
      path = Path.join(dir, Path.basename(before, ".before"))
      File.cp!(before, path)
      path
    end
  end

  defp expected(fixture, path),
    do: File.read!(Path.join([@fixtures, fixture, Path.basename(path) <> ".after"]))

  defp write(report), do: for({path, _, text} <- report.changed, do: File.write!(path, text))

  defp mapping,
    do: [
      mapping: @fixtures |> Path.join("verb_steps/mapping.json") |> File.read!() |> JSON.decode!()
    ]

  describe "verb_steps" do
    test "taps on a VerbGate's key become verb steps, comments kept", %{tmp_dir: dir} do
      [path] = app("verb_steps", dir)
      report = Upgrade.run(VerbSteps, [dir], mapping())
      write(report)

      assert File.read!(path) == expected("verb_steps", path)

      assert [
               %{
                 line: 21,
                 reason: ~s(VerbGates place "shared-key" for booking.cancel, booking.pay)
               }
             ] =
               report.skipped
    end

    test "a second run changes nothing", %{tmp_dir: dir} do
      app("verb_steps", dir)
      write(Upgrade.run(VerbSteps, [dir], mapping()))

      assert %{changed: []} = Upgrade.run(VerbSteps, [dir], mapping())
    end
  end

  describe "timed_rules" do
    test "a holds that only measures a timestamp against now becomes within:/since:", %{
      tmp_dir: dir
    } do
      paths = app("timed_rules", dir)
      report = Upgrade.run(TimedRules, [dir])
      write(report)

      for path <- paths, do: assert(File.read!(path) == expected("timed_rules", path), path)

      assert Enum.map(report.skipped, &{&1.line, &1.reason}) == [
               {19,
                "desired :paid_has_charge: holds is not a timestamp plus a fixed duration compared with now"},
               {23, "desired :draft_cleared: already has within:/since:"},
               {28,
                "desired :hold_released: holds is not a timestamp plus a fixed duration compared with now"},
               {29, "desired :elsewhere: Elsewhere.fine?/1 has no def in the files given"}
             ]
    end

    test "a second run changes nothing", %{tmp_dir: dir} do
      app("timed_rules", dir)
      write(Upgrade.run(TimedRules, [dir]))

      assert %{changed: []} = Upgrade.run(TimedRules, [dir])
    end

    test "each accepted shape names its window and field", %{tmp_dir: dir} do
      for {body, window} <- [
            {"DateTime.compare(DateTime.utc_now(), DateTime.add(r.at, 2, :hour)) == :lt",
             "{2, :hour}"},
            {"DateTime.before?(DateTime.utc_now(), DateTime.add(r.at, 90))", "{90, :second}"},
            {"NaiveDateTime.diff(NaiveDateTime.utc_now(), r.at) < 30", "{30, :second}"},
            {"NaiveDateTime.after?(NaiveDateTime.add(r.at, 3, :day), NaiveDateTime.utc_now())",
             "{3, :day}"}
          ] do
        assert rewritten(dir, body) =~ "within: #{window}, since: :at", body
      end
    end

    test "near misses stay as written", %{tmp_dir: dir} do
      for body <- [
            "DateTime.compare(DateTime.add(r.at, 2, :hour), DateTime.utc_now()) == :lt",
            "DateTime.compare(DateTime.add(r.at, 2, :week), DateTime.utc_now()) == :gt",
            "DateTime.compare(DateTime.add(r.at, -2, :hour), DateTime.utc_now()) == :gt",
            "DateTime.compare(NaiveDateTime.add(r.at, 2, :hour), DateTime.utc_now()) == :gt",
            "DateTime.diff(DateTime.utc_now(), r.at) <= 30",
            "DateTime.diff(r.at, DateTime.utc_now()) < 30",
            "DateTime.after?(DateTime.add(other.at, 2), DateTime.utc_now())",
            "r.active and DateTime.after?(DateTime.add(r.at, 2), DateTime.utc_now())"
          ] do
        assert rewritten(dir, body) =~ "holds: {__MODULE__, :ok?}", body
      end
    end

    test "holds names its module through the aliases in scope", %{tmp_dir: dir} do
      path = Path.join(dir, "nested.ex")

      File.write!(path, """
      defmodule App do
        alias App.Clock.Windows, as: W

        defmodule Booking do
          reconcile do
            desired :rule, "a rule", scope: expr(true), holds: {W, :young?}
          end
        end
      end

      defmodule App.Clock.Windows do
        def young?(r), do: DateTime.after?(DateTime.add(r.at, 5, :minute), DateTime.utc_now())
      end
      """)

      write(Upgrade.run(TimedRules, [path]))
      assert File.read!(path) =~ "within: {5, :minute}, since: :at"
    end

    test "a file that does not parse is reported", %{tmp_dir: dir} do
      path = Path.join(dir, "broken.ex")
      File.write!(path, "defmodule Broken do\n")

      assert %{changed: [], skipped: [%{path: ^path, reason: "does not parse"}]} =
               Upgrade.run(TimedRules, [dir])
    end

    defp rewritten(dir, body) do
      path = Path.join(dir, "rule.ex")

      File.write!(path, """
      defmodule R do
        reconcile do
          desired :rule, "a rule", scope: expr(true), holds: {__MODULE__, :ok?}
        end

        def ok?(r), do: #{body}
      end
      """)

      write(Upgrade.run(TimedRules, [path]))
      File.read!(path)
    end
  end

  describe "mix mana.upgrade" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "--dry-run prints the diff and writes nothing", %{tmp_dir: dir} do
      [path] = app("verb_steps", dir)

      Mix.Tasks.Mana.Upgrade.run([
        "verb_steps",
        dir,
        "--dry-run",
        "--mapping",
        Path.join(@fixtures, "verb_steps/mapping.json")
      ])

      assert File.read!(path) == File.read!(Path.join(@fixtures, "verb_steps/hosts.ex.before"))
      assert_received {:mix_shell, :info, [diff]}
      assert diff =~ ~s{-      step(:publish, tap: "property-detail-publish", until: [:public])}
      assert diff =~ "+      step(:publish, verb: {:property, :publish}, until: [:public])"
      assert_received {:mix_shell, :info, ["skipped " <> _]}
      assert_received {:mix_shell, :info, ["verb_steps: 1 file(s) to change, 1 skipped"]}
    end

    test "verb_steps refuses to run without the apps' mapping", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/--mapping/, fn ->
        Mix.Tasks.Mana.Upgrade.run(["verb_steps", dir])
      end
    end
  end

  test "the diff numbers each hunk like diff -u" do
    before = Enum.map_join(1..10, &"#{&1}\n")
    after_ = String.replace(before, "5\n", "five\n")

    assert Diff.unified("f.ex", before, after_) == """
           --- f.ex
           +++ f.ex
           @@ -2,7 +2,7 @@
            2
            3
            4
           -5
           +five
            6
            7
            8
           """
  end
end
