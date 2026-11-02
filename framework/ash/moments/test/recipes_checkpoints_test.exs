defmodule RecipesCheckpointsTest.Repo do
  use Ecto.Repo, otp_app: :moments, adapter: Ecto.Adapters.Postgres
end

defmodule RecipesCheckpointsTest.Recipes do
  use Moments.RecipeSet, observe: :observe

  @repo RecipesCheckpointsTest.Repo

  recipe :booking, "A booking, in a database of its own.", data_scope: true do
    send(self(), :booking_prepared)
    id = Ecto.UUID.generate()
    @repo.query!("INSERT INTO rows (id, label) VALUES ($1, 'booking')", [Ecto.UUID.dump!(id)])
    %{"route" => "/booking", "inputs" => %{"booking.id" => id}}
  end

  recipe :paid, "The parent's booking, paid.", data_scope: true do
    %{"inputs" => %{"booking.id" => id}} = context["parent"]

    @repo.query!("INSERT INTO rows (id, label) VALUES ($1, $2)", [
      Ecto.UUID.bingenerate(),
      "paid " <> id
    ])

    %{"route" => "/paid"}
  end

  recipe :shared, "Nothing scoped." do
    %{"route" => "/"}
  end

  def observe(_launch, _projection), do: {:ok, %{}}

  def labels do
    %{rows: rows} = @repo.query!("SELECT label FROM rows ORDER BY label")
    Enum.map(rows, &hd/1)
  end
end

defmodule Moments.RecipesCheckpointsTest do
  use ExUnit.Case, async: false
  @moduletag :postgres
  @moduletag :capture_log

  alias Mana.Snapshot
  alias RecipesCheckpointsTest.Recipes

  @repo RecipesCheckpointsTest.Repo
  @token String.duplicate("c", 40)

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
      for id <- Snapshot.scopes(@repo), do: Snapshot.drop(@repo, id)
      Snapshot.drop_snapshot(@repo, "c-booking")
      Application.delete_env(:mana_core, :data_scopes)
    end)
  end

  defp call(path, body) do
    options =
      Moments.Recipes.init(
        token: {__MODULE__, :token, []},
        recipes: Recipes.__recipes__(),
        repo: {@repo, migrations: Path.expand("support/data_scope_migrations", __DIR__)}
      )

    Plug.Test.conn(:post, path, body)
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> @token)
    |> Moments.Recipes.call(options)
    |> then(&{&1.status, Jason.decode!(&1.resp_body)})
  end

  defp labels(scope), do: Snapshot.with_scope(@repo, scope, &Recipes.labels/0)

  test "a child prepares in a clone of its parent's captured snapshot; the parent's recipe does not run again" do
    digest = Base.encode16(Recipes.module_info(:md5), case: :lower)

    assert {200, %{"dataScope" => true, "recipe" => ^digest, "snapshot" => false}} =
             call("/booking/describe", %{"snapshot" => "c-booking"})

    {200, parent} = call("/booking/prepare", %{"context" => %{}})
    assert_received :booking_prepared

    assert {200, %{"snapshot" => "c-booking"}} =
             call("/booking/capture", %{"launch" => parent, "snapshot" => "c-booking"})

    assert {200, %{"snapshot" => true}} = call("/booking/describe", %{"snapshot" => "c-booking"})

    # What the parent's open situation does after the capture is not part of it.
    Snapshot.with_scope(@repo, parent["dataScope"], fn ->
      @repo.query!("INSERT INTO rows (id, label) VALUES ($1, 'later')", [Ecto.UUID.bingenerate()])
    end)

    {200, child} =
      call("/paid/prepare", %{
        "context" => %{"parent" => parent},
        "from" => %{"snapshot" => "c-booking"}
      })

    refute_received :booking_prepared
    assert child["route"] == "/paid"
    assert child["dataScope"] not in [nil, parent["dataScope"]]
    assert labels(child["dataScope"]) == ["booking", "paid " <> parent["inputs"]["booking.id"]]
    assert labels(parent["dataScope"]) == ["booking", "later"]
  end

  test "only a data-scoped recipe captures or prepares from a snapshot, and only from one that exists" do
    {200, shared} = call("/shared/prepare", %{"context" => %{}})
    {200, parent} = call("/booking/prepare", %{"context" => %{}})

    assert {200, %{"dataScope" => false, "snapshot" => false}} = call("/shared/describe", %{})

    for {path, body} <- [
          {"/shared/capture", %{"launch" => shared, "snapshot" => "c-booking"}},
          {"/booking/capture", %{"launch" => shared, "snapshot" => "c-booking"}},
          {"/booking/capture", %{"launch" => parent, "snapshot" => "Not A Name"}},
          {"/shared/prepare", %{"from" => %{"snapshot" => "c-booking"}}},
          {"/paid/prepare", %{"from" => %{"snapshot" => "c-booking"}}},
          {"/paid/prepare", %{"from" => %{"snapshot" => "../etc"}}},
          {"/paid/prepare", %{"from" => "c-booking"}}
        ] do
      assert {422, %{"error" => "recipe_failed"}} = call(path, body), "#{path} #{inspect(body)}"
    end
  end
end
