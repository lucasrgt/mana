defmodule __Name__.NotesTest do
  use ExUnit.Case, async: true
  require Ash.Query

  test "a note goes on its list and can be completed once" do
    list = "list-" <> Ash.UUID.generate()
    note = Ash.create!(__Name__.Notes.Note, %{list: list, title: "Buy bread"}, action: :add)

    assert [%{title: "Buy bread", done: false}] =
             __Name__.Notes.Note |> Ash.Query.for_read(:in_list, %{list: list}) |> Ash.read!()
    assert "complete" in Mana.Verbs.offered(note, nil)

    done = Ash.update!(note, %{}, action: :complete)
    assert done.done
    refute "complete" in Mana.Verbs.offered(done, nil)
    assert {:error, _} = Ash.update(done, %{}, action: :complete)
  end
end
