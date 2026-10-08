defmodule __Name__.Moments do
  @moduledoc """
  The app's Moments: named situations the engine opens and checks. Recipes
  put the backend in place through the app's own actions; `Moments.App`
  declares what the screen reports and what each Moment must show.
  """
  def recipes, do: __Name__.Moments.Recipes.__recipes__()
end

defmodule __Name__.Moments.Recipes do
  @moduledoc "Backend situations, served to the engine in development only."
  use Moments.RecipeSet, observe: :observe
  require Ash.Query

  recipe :empty_list, "A fresh list nobody wrote on yet." do
    %{"route" => "/", "fixture" => "list-" <> Ash.UUID.generate(), "inputs" => %{"note.title" => "Buy bread"}}
  end

  def observe(launch, _projection) do
    list = launch["fixture"]
    notes = __Name__.Notes.Note |> Ash.Query.filter(list == ^list) |> Ash.count!()
    {:ok, %{"fixture" => list, "notes" => notes}}
  end
end

defmodule __Name__.Moments.App do
  @moduledoc "Moments of the app in app/."
  use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

  resources do
  end

  moments do
    route("/")
    client_roots(["lib/app.dart"])

    field(:notes, 0, min: 0, max: 1000, restore: false)
    field(:fixture, "none", max_length: 80, restore: false)
    field(:scrollOffset, 0, min: 0, max: 0)

    moment :notes_empty do
      backend(:empty_list)
      description("A list with nothing on it yet.")
      check(:empty, kind: :ui_equals, field: :notes, equals: 0)
    end

    moment :note_added do
      backend(:empty_list)
      description("A note written on the list shows on the screen and is stored.")
      step(:title, fill: "note-title", from: "note.title")
      step(:add, tap: "note-add", until: [:shown, :saved])
      check(:shown, kind: :ui_equals, field: :notes, equals: 1)
      check(:saved, kind: :backend_equals, field: :notes, equals: 1, match: :fixture)
    end
  end
end
