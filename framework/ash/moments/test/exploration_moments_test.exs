defmodule ExplorationMomentsTest.Repo do
  use Ecto.Repo, otp_app: :moments, adapter: Ecto.Adapters.Postgres
end

defmodule ExplorationMomentsTest.Rules do
  def has_reason?(ticket),
    do: if(ticket.reason, do: true, else: {false, "closed without a reason"})
end

# The seeded bug: `close` forgets the reason until the app is fixed.
defmodule ExplorationMomentsTest.Ticket do
  @moduledoc false
  use Ash.Resource,
    domain: ExplorationMomentsTest.Tickets,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs, Mana.Reconcile]

  attributes do
    uuid_primary_key(:id)

    attribute(:status, :atom,
      constraints: [one_of: [:open, :closed]],
      default: :open,
      public?: true
    )

    attribute(:reason, :string, public?: true)
  end

  actions do
    defaults([:read])
    create(:start)

    update :close do
      require_atomic?(false)
      change(set_attribute(:status, :closed))

      change(fn changeset, _ ->
        if Application.get_env(:moments, :exploration_fixed, false),
          do: Ash.Changeset.force_change_attribute(changeset, :reason, "resolved"),
          else: changeset
      end)
    end
  end

  verbs do
    verb(:start, collection: true)
    verb(:close, when: expr(status == :open))
  end

  reconcile do
    desired(:closed_has_reason, "every closed ticket says why",
      scope: expr(status == :closed),
      holds: {ExplorationMomentsTest.Rules, :has_reason?}
    )
  end
end

defmodule ExplorationMomentsTest.Tickets do
  use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

  @explorations Path.join(System.tmp_dir!(), "moments-exploration-moments-test")
  def explorations, do: @explorations

  resources do
    resource(ExplorationMomentsTest.Ticket)
  end

  moments do
    app(:desk)
    explorations(@explorations)
  end
end

defmodule ExplorationMomentsTest.Desk do
  use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

  resources do
  end

  moments do
    app(:desk)
    route("/desk")
    base(:desk_workspace)
    field(:page, 0, min: 0, max: 9)

    moment :front do
      description("The desk's front page.")
      backend(:front)
    end
  end
end

defmodule ExplorationMomentsTest.Explore do
  def options,
    do: [domains: [ExplorationMomentsTest.Tickets], actors: actors(), runs: 10, depth: 4]

  # The tickets are on ETS, outside any data scope: a replay starts from none.
  def actors do
    Mana.Explore.empty_ets(ExplorationMomentsTest.Ticket)
    %{agent: nil}
  end
end

defmodule Moments.ExplorationMomentsTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias ExplorationMomentsTest.{Desk, Explore, Tickets}

  @repo ExplorationMomentsTest.Repo
  @token String.duplicate("t", 40)

  def token, do: @token

  setup do
    File.rm_rf!(Tickets.explorations())

    on_exit(fn ->
      File.rm_rf!(Tickets.explorations())
      Application.delete_env(:moments, :exploration_fixed)
      Application.delete_env(:mana_core, :explore)
    end)
  end

  defp manifest, do: Moments.Manifest.build(Desk, domains: [Desk, Tickets], source_root: __DIR__)

  defp save(name) do
    Application.put_env(:mana_core, :explore, Explore)
    Mix.shell(Mix.Shell.Process)

    try do
      catch_exit(Mix.Tasks.Mana.Explore.run(["--save", name, "--out", Tickets.explorations()]))
    after
      Mix.shell(Mix.Shell.IO)
    end
  end

  test "every trace saved in a section's explorations directory is a Moment of its app" do
    assert {:shutdown, 1} = save("closed_ticket")
    assert_received {:mix_shell, :info, ["saved Moment closed-ticket: " <> path]}
    moment = manifest()["moments"]["closed-ticket"]

    assert moment["description"] =~
             "Found by Mana.Explore: invariant breaks for ExplorationMomentsTest.Ticket.closed_has_reason"

    assert moment["projection"] == %{"page" => 0, "route" => "/desk"}
    assert moment["checks"] == [%{"name" => "invariant", "kind" => "property"}]
    assert moment["steps"] == []
    refute Map.has_key?(moment, "backend"), "the trace is its recipe: the app's base is not"

    assert %{"file" => file, "sha256" => sha, "trace" => trace} = moment["exploration"]
    assert trace == path |> File.read!() |> Jason.decode!()
    assert Path.expand(file, __DIR__) == path
    assert sha == :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

    assert [%{"domain" => domain, "directory" => directory, "resources" => resources}] =
             manifest()["explorations"]

    assert {domain, Path.expand(directory, __DIR__)} == {inspect(Tickets), Tickets.explorations()}
    assert resources == ["ExplorationMomentsTest.Ticket"]
  end

  # Spark records where a declaration is only with debug_info, which test
  # files are compiled without: these domains are compiled with it.
  @sited """
  defmodule ExplorationMomentsTest.SitedTickets do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      app(:sited)
      explorations(ExplorationMomentsTest.Tickets.explorations())
    end
  end

  defmodule ExplorationMomentsTest.SitedDesk do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      app(:sited)
      route("/sited")
    end
  end
  """

  test "an exploration Moment's source is the explorations line of the domain that declares it" do
    assert {:shutdown, 1} = save("closed-ticket")
    debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    try do
      Code.compile_string(@sited, __ENV__.file)
    after
      Code.put_compiler_option(:debug_info, debug_info)
    end

    [desk, tickets] = [ExplorationMomentsTest.SitedDesk, ExplorationMomentsTest.SitedTickets]
    manifest = Moments.Manifest.build(desk, domains: [desk, tickets], source_root: __DIR__)

    assert %{"file" => "exploration_moments_test.exs", "line" => line, "module" => module} =
             manifest["moments"]["closed-ticket"]["source"]

    assert module == inspect(tickets)
    assert @sited |> String.split("\n") |> Enum.at(line - 1) =~ "explorations("
  end

  test "nothing saved yet declares no Moment; a file that is no trace or no Moment name is refused" do
    assert Map.keys(manifest()["moments"]) == ["front"]
    File.mkdir_p!(Tickets.explorations())

    for {file, contents, refusal} <- [
          {"Closed.json", ~s({"property": "invariant", "moves": []}), "named after its Moment"},
          {"closed.json", ~s({"moves": "none"}), "not a Mana.Explore trace"},
          {"front.json", ~s({"property": "invariant", "moves": []}), "duplicate"}
        ] do
      path = Path.join(Tickets.explorations(), file)
      File.write!(path, contents)
      assert_raise ArgumentError, ~r/#{refusal}/, &manifest/0
      File.rm!(path)
    end
  end

  describe "running an exploration Moment" do
    @describetag :postgres

    setup do
      Application.put_env(:moments, @repo,
        url: System.get_env("MANA_TEST_POSTGRES"),
        pool_size: 2,
        log: false
      )

      {:ok, _} = Application.ensure_all_started(:ecto_sql)
      {:ok, _} = Application.ensure_all_started(:postgrex)
      Application.put_env(:mana_core, :data_scopes, true)

      on_exit(fn ->
        for id <- Mana.Snapshot.scopes(@repo), do: Mana.Snapshot.drop(@repo, id)
        Application.delete_env(:mana_core, :data_scopes)
      end)
    end

    defp check(trace) do
      options =
        Moments.Recipes.init(
          token: {__MODULE__, :token, []},
          recipes: %{},
          repo: {@repo, migrations: Path.expand("support/data_scope_migrations", __DIR__)},
          explore: [domains: [Tickets], setup: {Explore, :actors, []}]
        )

      Plug.Test.conn(:post, "/_explorations/check", %{"trace" => trace})
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @token)
      |> Moments.Recipes.call(options)
      |> then(&{&1.status, Jason.decode!(&1.resp_body)})
    end

    test "a seeded bug found by mix mana.explore --save is a Moment that fails, and passes once fixed" do
      assert {:shutdown, 1} = save("closed-ticket")
      trace = manifest()["moments"]["closed-ticket"]["exploration"]["trace"]

      assert {200, %{"status" => "failed", "violation" => violation}} = check(trace)

      assert %{
               "property" => "invariant",
               "resource" => "ExplorationMomentsTest.Ticket",
               "verb" => "closed_has_reason",
               "detail" => detail
             } = violation

      assert detail =~ "closed without a reason"
      assert Mana.Snapshot.scopes(@repo) == [], "each check replays in a scope it drops"

      Application.put_env(:moments, :exploration_fixed, true)
      assert {200, %{"status" => "passed", "property" => "invariant"}} = check(trace)
    end

    test "a trace that is not one is refused" do
      assert {422, %{"error" => "recipe_failed"}} = check(%{"moves" => []})
    end
  end
end
