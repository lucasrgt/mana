defmodule RecipesSituationsTest.Repo do
  use Ecto.Repo, otp_app: :moments, adapter: Ecto.Adapters.Postgres
end

defmodule RecipesSituationsTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(RecipesSituationsTest.Note)
    resource(RecipesSituationsTest.Entry)
  end
end

defmodule RecipesSituationsTest.Entry do
  @moduledoc false
  use Ash.Resource,
    domain: RecipesSituationsTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.History.Log]

  history_log do
    subjects([RecipesSituationsTest.Note])
  end
end

defmodule RecipesSituationsTest.Note do
  @moduledoc false
  use Ash.Resource,
    domain: RecipesSituationsTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.History]

  history do
    log(RecipesSituationsTest.Entry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:text, :string, public?: true)
  end

  actions do
    defaults([:read, create: [:text]])
  end
end

defmodule RecipesSituationsTest.Recipes do
  use Moments.RecipeSet, observe: :observe

  @repo RecipesSituationsTest.Repo

  recipe :one_row, "One row and one note, in a database of its own.", data_scope: true do
    @repo.query!("INSERT INTO rows (id, label) VALUES ($1, 'a')", [Ecto.UUID.bingenerate()])
    Ash.create!(RecipesSituationsTest.Note, %{text: "situation"}, authorize?: false)
    %{"route" => "/"}
  end

  recipe :with_knobs, "Settings of its own, outside the database.", data_scope: true do
    %{"route" => "/", "knobScope" => "k-1"}
  end

  recipe :shared, "Nothing scoped." do
    %{"route" => "/"}
  end

  def observe(_launch, _projection), do: {:ok, %{"rows" => rows()}}

  def rows do
    %{rows: [[count]]} = @repo.query!("SELECT count(*) FROM rows")
    count
  end
end

defmodule Moments.RecipesSituationsTest do
  use ExUnit.Case, async: false
  @moduletag :postgres
  # Refused operations log their reason; the log is shown only on failure.
  @moduletag :capture_log

  alias Mana.Snapshot
  alias RecipesSituationsTest.Recipes

  @repo RecipesSituationsTest.Repo
  @token String.duplicate("t", 40)

  def token, do: @token

  # The exploration's people, created where the replay runs.
  def actors do
    @repo.query!("INSERT INTO rows (id, label) VALUES ($1, 'actor')", [Ecto.UUID.bingenerate()])
    %{}
  end

  setup_all do
    Application.put_env(:moments, @repo,
      url: System.get_env("MANA_TEST_POSTGRES"),
      pool_size: 2,
      log: false
    )

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    :ok
  end

  setup do
    Application.put_env(:mana_core, :data_scopes, true)

    on_exit(fn ->
      for id <- Snapshot.scopes(@repo), do: Snapshot.drop(@repo, id)
      Application.delete_env(:mana_core, :data_scopes)
    end)
  end

  defp call(path, body) do
    options =
      Moments.Recipes.init(
        token: {__MODULE__, :token, []},
        recipes: Recipes.__recipes__(),
        repo: {@repo, migrations: Path.expand("support/data_scope_migrations", __DIR__)},
        history: [RecipesSituationsTest.Entry],
        explore: [domains: [RecipesSituationsTest.Domain], setup: {__MODULE__, :actors, []}]
      )

    Plug.Test.conn(:post, path, body)
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> @token)
    |> Moments.Recipes.call(options)
    |> then(&{&1.status, Jason.decode!(&1.resp_body)})
  end

  defp rows_in(scope), do: Snapshot.with_scope(@repo, scope, &Recipes.rows/0)

  defp prepared do
    {200, launch} = call("/one-row/prepare", %{"context" => %{}})
    launch
  end

  test "a fork clones the whole prepared situation n times, each copy independent of the others" do
    launch = prepared()

    {200, %{"launches" => [a, b] = launches}} =
      call("/one-row/fork", %{"launch" => launch, "n" => 2})

    scopes = Enum.map(launches, & &1["dataScope"])
    assert length(Enum.uniq([launch["dataScope"] | scopes])) == 3
    assert Enum.all?(launches, &(Map.delete(&1, "dataScope") == Map.delete(launch, "dataScope")))
    assert Enum.map(scopes, &rows_in/1) == [1, 1]

    Snapshot.with_scope(@repo, a["dataScope"], fn ->
      @repo.query!("INSERT INTO rows (id, label) VALUES ($1, 'only-a')", [Ecto.UUID.bingenerate()])
    end)

    assert rows_in(a["dataScope"]) == 2
    assert rows_in(b["dataScope"]) == 1
    assert rows_in(launch["dataScope"]) == 1
    refute Snapshot.snapshot?(@repo, "fork_" <> launch["dataScope"])
  end

  test "only a known data scope forks, without settings of its own, 1 to 16 times" do
    launch = prepared()
    {200, shared} = call("/shared/prepare", %{"context" => %{}})
    {200, knobbed} = call("/with-knobs/prepare", %{"context" => %{}})

    for {body, _why} <- [
          {%{"launch" => shared, "n" => 1}, :no_scope},
          {%{"launch" => %{launch | "dataScope" => "000000000000"}, "n" => 1}, :unknown},
          {%{"launch" => knobbed, "n" => 1}, :knob_scope},
          {%{"launch" => launch, "n" => 0}, :count},
          {%{"launch" => launch, "n" => 17}, :count},
          {%{"launch" => launch, "n" => "2"}, :count}
        ] do
      assert {422, %{"error" => "recipe_failed"}} = call("/one-row/fork", body)
    end
  end

  test "a projection counts every table and lists history in order, with the recipe's digest" do
    launch = prepared()

    {200, projection} = call("/one-row/project", %{"launch" => launch})

    assert projection["tables"] == %{"rows" => 1}
    assert projection["recipe"] == Base.encode16(Recipes.module_info(:md5), case: :lower)

    assert %{"action" => "create", "outcome" => "done", "after" => %{"text" => "situation"}} =
             Enum.find(projection["history"], &(&1["after"]["text"] == "situation"))

    assert {422, _} = call("/one-row/project", %{"launch" => %{"route" => "/"}})
  end

  test "a saved exploration replays in a scope of its own, its actors created there" do
    {200, %{"dataScope" => scope, "records" => records}} =
      call("/_explorations/replay", %{"trace" => %{"property" => "offer_honest", "moves" => []}})

    assert is_integer(records)
    assert scope in Snapshot.scopes(@repo)
    assert rows_in(scope) == 1

    {200, %{"tables" => %{"rows" => 1}, "recipe" => nil}} =
      call("/_explorations/project", %{"launch" => %{"dataScope" => scope}})

    {200, %{"launches" => [%{"dataScope" => fork}]}} =
      call("/_explorations/fork", %{"launch" => %{"dataScope" => scope}, "n" => 1})

    assert rows_in(fork) == 1
    assert {422, _} = call("/_explorations/replay", %{"trace" => %{"moves" => "none"}})
  end
end
