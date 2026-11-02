defmodule RecipesScopeTest.Repo do
  use Ecto.Repo, otp_app: :moments, adapter: Ecto.Adapters.Postgres
end

defmodule RecipesScopeTest.Recipes do
  use Moments.RecipeSet, observe: :observe

  @repo RecipesScopeTest.Repo

  recipe :own_rows, "Two rows in a database of its own.", data_scope: true do
    for label <- ["a", "b"],
        do:
          @repo.query!("INSERT INTO rows (id, label) VALUES ($1, $2)", [
            Ecto.UUID.bingenerate(),
            label
          ])

    %{"route" => "/"}
  end

  recipe :shared, "Nothing scoped." do
    %{"route" => "/"}
  end

  def observe(_launch, _projection) do
    %{rows: [[count]]} = @repo.query!("SELECT count(*) FROM rows")
    {:ok, %{"rows" => count}}
  end
end

defmodule Moments.RecipesDataScopeTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  @repo RecipesScopeTest.Repo
  @token String.duplicate("t", 40)

  def token, do: @token

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
      for id <- Mana.Snapshot.scopes(@repo), do: Mana.Snapshot.drop(@repo, id)
      Application.delete_env(:mana_core, :data_scopes)
    end)
  end

  defp call(path, body) do
    migrations = Path.expand("support/data_scope_migrations", __DIR__)

    options =
      Moments.Recipes.init(
        token: {__MODULE__, :token, []},
        recipes: RecipesScopeTest.Recipes.__recipes__(),
        repo: {@repo, migrations: migrations}
      )

    Plug.Test.conn(:post, path, body)
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> @token)
    |> Moments.Recipes.call(options)
    |> then(&{&1.status, Jason.decode!(&1.resp_body)})
  end

  test "a data_scope recipe prepares in its own database and observes there" do
    {200, %{"dataScope" => scope} = launch} = call("/own-rows/prepare", %{"context" => %{}})
    {200, %{"dataScope" => other}} = call("/own-rows/prepare", %{"context" => %{}})
    assert scope != other

    assert {200, %{"rows" => 2}} =
             call("/own-rows/observe", %{"launch" => launch, "projection" => %{}})

    assert Mana.Snapshot.with_scope(@repo, other, fn ->
             @repo.query!("SELECT count(*) FROM rows").rows
           end) == [[2]]

    assert {200, launch} = call("/shared/prepare", %{"context" => %{}})
    refute Map.has_key?(launch, "dataScope")
  end

  test "a data_scope recipe is refused when scopes are off" do
    Application.put_env(:mana_core, :data_scopes, false)

    assert_raise ArgumentError, ~r/data_scopes: true/, fn ->
      call("/own-rows/prepare", %{"context" => %{}})
    end
  end
end
