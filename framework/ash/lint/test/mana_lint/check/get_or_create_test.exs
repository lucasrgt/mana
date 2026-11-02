defmodule ManaLint.Check.GetOrCreateTest do
  use Credo.Test.Case

  alias ManaLint.Check.GetOrCreate, as: Check

  test "read_one || create" do
    """
    defmodule App.Open do
      def run(query, attrs) do
        Ash.read_one!(query, authorize?: false) ||
          case Ash.create(App.Chat, attrs, authorize?: false) do
            {:ok, chat} -> chat
            {:error, _} -> Ash.read_one!(query, authorize?: false)
          end
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(&assert(&1.trigger == "Ash.create"))
  end

  test "case {:ok, nil}, with nil <- and a variable tested with if" do
    """
    defmodule App.Follow do
      def a(q, attrs) do
        case Ash.read_one(q) do
          {:ok, nil} -> Ash.create(App.Follow, attrs)
          {:ok, follow} -> {:ok, follow}
        end
      end

      def b(q, attrs) do
        with nil <- Ash.read_one!(q) do
          Ash.create!(App.Follow, attrs)
        end
      end

      def c(q, attrs) do
        existing = Ash.read_one!(q)
        if existing, do: existing, else: Ash.create!(App.Follow, attrs)
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issues(&assert(length(&1) == 3))
  end

  test "an upsert, a create after a found record and different resources are fine" do
    """
    defmodule App.Fine do
      def a(q, attrs), do: Ash.read_one!(q) || Ash.create!(App.Chat, attrs, upsert?: true)

      def b(q, attrs) do
        case Ash.read_one(q) do
          {:ok, %{} = chat} -> Ash.create(App.Message, %{chat_id: chat.id})
          other -> other
        end
      end

      def c(attrs), do: Ash.read_one!(App.Plan) || Ash.create!(App.Audit, attrs)
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end
end
