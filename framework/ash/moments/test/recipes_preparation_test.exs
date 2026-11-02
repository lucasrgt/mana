defmodule RecipesPreparationTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(RecipesPreparationTest.Note)
  end
end

defmodule RecipesPreparationTest.Note do
  @moduledoc false
  use Ash.Resource, domain: RecipesPreparationTest.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key(:id)
    attribute(:text, :string, public?: true)
  end

  actions do
    defaults([:read, create: [:text]])

    update :touch do
      accept([:text])
    end
  end
end

defmodule RecipesPreparationTest.Recipes do
  use Moments.RecipeSet, observe: :observe
  alias RecipesPreparationTest.Note

  recipe :touched, "A note created, then touched." do
    Note
    |> Ash.create!(%{text: "a"}, authorize?: false)
    |> Ash.update!(%{text: "b"}, action: :touch)

    %{"route" => "/notes"}
  end

  recipe :many, "Several notes, all within the capture." do
    for _ <- 1..3, do: Ash.create!(Note, %{text: "a"}, authorize?: false)
    %{"route" => "/notes"}
  end

  def observe(_launch, projection), do: {:ok, projection}
end

defmodule Moments.RecipesPreparationTest do
  # The tracer is global Ash configuration.
  use ExUnit.Case, async: false
  alias Moments.ActionTrace
  alias RecipesPreparationTest.{Note, Recipes}

  @token String.duplicate("t", 40)
  def token, do: @token

  setup do
    previous = Application.fetch_env(:ash, :tracer)
    Application.put_env(:ash, :tracer, [ActionTrace])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash, :tracer, value)
        :error -> Application.delete_env(:ash, :tracer)
      end
    end)
  end

  defp prepare(name) do
    options =
      Moments.Recipes.init(token: {__MODULE__, :token, []}, recipes: Recipes.__recipes__())

    conn =
      Plug.Test.conn(:post, "/#{name}/prepare", %{"context" => %{}})
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @token)
      |> Moments.Recipes.call(options)

    preparation =
      case Plug.Conn.get_resp_header(conn, "x-mana-preparation") do
        [value] -> value |> Base.url_decode64!(padding: false) |> Jason.decode!()
        [] -> nil
      end

    {conn.status, Jason.decode!(conn.resp_body), preparation}
  end

  test "a preparation answers the actions it ran beside a launch that stays the recipe's own" do
    assert {200, %{"route" => "/notes"} = launch, preparation} = prepare("touched")
    assert map_size(launch) == 1

    assert preparation == %{
             "version" => 1,
             "truncated" => false,
             "actions" => [
               "RecipesPreparationTest.Note.create",
               "RecipesPreparationTest.Note.touch"
             ]
           }

    # The capture ends with the request.
    assert ActionTrace.get_span_context() == nil
  end

  test "without the Moments tracer a preparation claims nothing" do
    Application.delete_env(:ash, :tracer)
    assert {200, %{"route" => "/notes"}, nil} = prepare("touched")
  end

  test "past its limit a capture keeps writes over reads, and says when one is lost" do
    ActionTrace.begin_request("prepare", 2)
    for _ <- 1..3, do: Ash.read!(Note, authorize?: false)
    Ash.create!(Note, %{text: "a"}, authorize?: false)
    trace = ActionTrace.finish_request()

    assert trace.truncated
    assert trace.writesComplete
    assert [%{action: "read"}, %{action: "create"}] = trace.actions

    ActionTrace.begin_request("prepare", 2)
    for _ <- 1..3, do: Ash.create!(Note, %{text: "a"}, authorize?: false)
    trace = ActionTrace.finish_request()

    assert trace.truncated
    refute trace.writesComplete
    assert length(trace.actions) == 2
  end

  test "an untruncated capture says nothing about writes" do
    ActionTrace.begin_request("prepare", 8)
    Ash.read!(Note, authorize?: false)
    trace = ActionTrace.finish_request()

    refute trace.truncated
    refute Map.has_key?(trace, :writesComplete)
    assert {200, _launch, %{"truncated" => false} = answer} = prepare("many")
    refute Map.has_key?(answer, "writesComplete")
  end
end
