defmodule SearchTest.Place do
  @moduledoc false
  use Ash.Resource, domain: SearchTest.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:tags, {:array, :string}, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:name, :tags]])

    read :search do
      argument(:q, :string)
      prepare({Mana.Search, fields: [:name, :tags]})
    end

    read :search_unaccented do
      argument(:q, :string)
      prepare({Mana.Search, fields: [:name], unaccent: true})
    end
  end
end

defmodule SearchTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SearchTest.Place)
  end
end

defmodule Mana.SearchTest do
  use ExUnit.Case, async: false

  alias SearchTest.Place

  setup do
    Place |> Ash.read!() |> Enum.each(&Ash.destroy!/1)
    :ok
  end

  defp search(text, action \\ :search) do
    Place
    |> Ash.Query.for_read(action, %{q: text})
    |> Ash.read!()
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  test "on ETS, plain and array fields match in memory, ignoring case, with wildcards as text" do
    Ash.create!(Place, %{name: "Casa Azul", tags: ["Praia", "50% off"]})
    Ash.create!(Place, %{name: "100% natural"})
    Ash.create!(Place, %{name: "100 natural", tags: ["50 off"]})

    assert search("casa") == ["Casa Azul"]
    assert search("PRAIA") == ["Casa Azul"]
    assert search("100%") == ["100% natural"]
    assert search("50%") == ["Casa Azul"]
    assert search("_") == []
    assert search("  ") == ["100 natural", "100% natural", "Casa Azul"]
    assert search(nil) == ["100 natural", "100% natural", "Casa Azul"]
  end

  test "on ETS, unaccent refuses the read instead of matching accents" do
    assert_raise ArgumentError, ~r/`unaccent: true` needs AshPostgres/, fn ->
      search("", :search_unaccented)
    end
  end

  test "unaccent must be a boolean" do
    assert {:error, _} = Mana.Search.init(fields: [:name], unaccent: :yes)
    assert {:error, _} = Mana.Search.init(fields: [])
  end
end

defmodule Mana.SearchPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres
  require Ash.Query

  alias PostgresTest.{Harness, Place, Repo}

  setup_all do: Harness.start!()

  setup do
    Repo.query!("TRUNCATE places")
    :ok
  end

  defp search(text, action \\ :search) do
    Place
    |> Ash.Query.for_read(action, %{q: text})
    |> Ash.read!()
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  test "without unaccent, plain fields still filter with exactly the ilike they always did" do
    query = Ash.Query.for_read(Place, :search_plain, %{q: " 5%_\\ "})
    pattern = "%5\\%\\_\\\\%"
    expected = Ash.Query.filter(Place, ilike(name, ^pattern) or ilike(city, ^pattern))

    assert inspect(query.filter) == inspect(expected.filter)
  end

  test "unaccent matches accents both ways, and only when asked" do
    Ash.create!(Place, %{name: "São João"})
    Ash.create!(Place, %{name: "Sao Paulo"})

    assert search("Sao Joao", :search_unaccented) == ["São João"]
    assert search("SÃO PAULO", :search_unaccented) == ["Sao Paulo"]
    assert search("são", :search_unaccented) == ["Sao Paulo", "São João"]
    assert search("Sao Joao") == []
    assert search("São Paulo") == []
  end

  test "%, _ and \\ are text, with and without unaccent" do
    for name <- ["100% natural", "100 natural", "a_b", "axb", "back\\slash", "backslash"],
        do: Ash.create!(Place, %{name: name})

    for action <- [:search, :search_unaccented] do
      assert search("100%", action) == ["100% natural"]
      assert search("a_b", action) == ["a_b"]
      assert search("\\", action) == ["back\\slash"]
    end
  end

  test "an array field matches when any element does" do
    Ash.create!(Place, %{name: "Casa Azul", tags: ["Praia", "Café da manhã", "50% off"]})
    Ash.create!(Place, %{name: "Casa Verde", tags: ["Montanha", "50 off"]})
    Ash.create!(Place, %{name: "Casa Branca", tags: nil})
    Ash.create!(Place, %{name: "Casa Vazia", tags: []})

    assert search("praia") == ["Casa Azul"]
    assert search("CAFÉ") == ["Casa Azul"]
    assert search("cafe") == []
    assert search("cafe", :search_unaccented) == ["Casa Azul"]
    assert search("MANHA", :search_unaccented) == ["Casa Azul"]
    assert search("montanha") == ["Casa Verde"]
    assert search("50%") == ["Casa Azul"]
    assert search("50%", :search_unaccented) == ["Casa Azul"]
    assert search("deserto") == []
  end

  test "a blank text leaves the read alone" do
    Ash.create!(Place, %{name: "São João", tags: ["Praia"]})
    Ash.create!(Place, %{name: "Sao Paulo"})

    for action <- [:search, :search_unaccented],
        text <- [nil, "", "   "],
        do: assert(search(text, action) == ["Sao Paulo", "São João"])
  end
end
