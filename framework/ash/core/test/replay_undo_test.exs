defmodule ReplayTest.Entry do
  @moduledoc false
  use Ash.Resource,
    domain: ReplayTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.History.Log]

  history_log do
    subjects([ReplayTest.Wallet])
  end
end

defmodule ReplayTest.Wallet do
  @moduledoc false
  use Ash.Resource,
    domain: ReplayTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs, Mana.History]

  history do
    log(ReplayTest.Entry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:balance, :integer, default: 0, public?: true)
    attribute(:frozen, :boolean, default: false, public?: true)
  end

  actions do
    defaults([:read, :destroy])
    create(:open)

    update :deposit do
      require_atomic?(false)
      argument(:amount, :integer, allow_nil?: false)

      # Computed when the action runs, not while a changeset is built: an offer
      # check builds one without input.
      change(fn changeset, _ ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          bonus = Application.get_env(:mana_core, :replay_test_bonus, 0)
          amount = Ash.Changeset.get_argument(changeset, :amount)

          Ash.Changeset.force_change_attribute(
            changeset,
            :balance,
            changeset.data.balance + amount + bonus
          )
        end)
      end)
    end

    update(:freeze, change: set_attribute(:frozen, true))
    update(:thaw, change: set_attribute(:frozen, false))
  end

  verbs do
    verb(:open, collection: true, feature: "wallet")
    verb(:deposit, feature: "wallet/deposit")
    verb(:freeze, when: expr(frozen == false), inverse: :thaw, feature: "wallet")
    verb(:thaw, when: expr(frozen == true), inverse: :freeze, feature: "wallet")
  end
end

defmodule ReplayTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ReplayTest.Entry)
    resource(ReplayTest.Wallet)
  end
end

defmodule Mana.ReplayUndoTest do
  use ExUnit.Case, async: false

  alias Ash.Domain.Info

  @me %{id: "0d4c7a52-5d2f-4a8e-9f61-3b2a1c0e9a01"}
  @other %{id: "6f1e2d3c-4b5a-4968-8776-a5b4c3d2e1f0"}

  setup do
    for r <- Info.resources(ReplayTest.Domain), do: Mana.Explore.empty_ets(r)
    on_exit(fn -> Application.delete_env(:mana_core, :replay_test_bonus) end)
  end

  defp exported do
    ReplayTest.Entry
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn e ->
      e
      |> Map.take([
        :id,
        :subject_type,
        :subject_id,
        :action,
        :verb,
        :actor_id,
        :actor_kind,
        :params,
        :before,
        :after,
        :outcome,
        :at
      ])
      |> Jason.encode!()
      |> Jason.decode!()
    end)
  end

  defp wallet_with(amounts) do
    wallet = Ash.create!(ReplayTest.Wallet, %{}, action: :open, actor: @me)
    Enum.reduce(amounts, wallet, &Ash.update!(&2, %{amount: &1}, action: :deposit, actor: @me))
  end

  describe "replay" do
    test "the same code rebuilds every subject the same, and writes nothing" do
      wallet_with([10, 5])
      wallet_with([1])
      entries = exported()
      before = length(Ash.read!(ReplayTest.Wallet))

      report = Mana.Replay.run(entries, domains: [ReplayTest.Domain])

      assert report.subjects == 2
      assert Enum.all?(report.results, &(&1.outcome == :same)), inspect(report.results)
      assert report.by_feature == %{"wallet" => %{same: 2}}
      assert length(Ash.read!(ReplayTest.Wallet)) == before
    end

    test "a changed rule shows as divergence on exactly the subjects it changes" do
      deposited = wallet_with([10])
      _untouched = Ash.create!(ReplayTest.Wallet, %{}, action: :open, actor: @me)
      entries = exported()

      Application.put_env(:mana_core, :replay_test_bonus, 1)
      report = Mana.Replay.run(entries, domains: [ReplayTest.Domain])

      assert [%{subject: subject, fields: [%{field: "balance", recorded: 10, replayed: 11}]}] =
               Enum.filter(report.results, &(&1.outcome == :diverged))

      assert subject == "wallet:#{deposited.id}"
      assert Mana.Replay.format(report) =~ "balance 10 → 11"
    end

    test "reads JSON lines" do
      wallet_with([3])
      path = Path.join(System.tmp_dir!(), "replay-#{System.unique_integer([:positive])}.jsonl")
      File.write!(path, Enum.map(exported(), &[Jason.encode!(&1), "\n"]))
      assert length(Mana.Replay.read(path)) == 2
    end
  end

  describe "undo" do
    test "takes back the newest change through its inverse, and records what it undid" do
      wallet = Ash.create!(ReplayTest.Wallet, %{}, action: :open, actor: @me)
      frozen = Ash.update!(wallet, %{}, action: :freeze, actor: @me)

      assert %{verb: %{name: :freeze}, inverse: %{name: :thaw}, entry: entry} =
               Mana.Undo.last(frozen, @me)

      assert {:ok, %{frozen: false} = thawed} = Mana.Undo.undo(frozen, @me)

      [newest | _] = ReplayTest.Entry |> Ash.Query.sort(at: :desc) |> Ash.read!(authorize?: false)
      assert newest.via == "undo:#{entry.id}"
      # an undo is not itself undone
      assert Mana.Undo.last(thawed, @me) == nil
    end

    test "only the person who made the newest change may undo it, and only while its inverse is offered" do
      wallet = Ash.create!(ReplayTest.Wallet, %{}, action: :open, actor: @me)
      frozen = Ash.update!(wallet, %{}, action: :freeze, actor: @me)

      assert Mana.Undo.last(frozen, @other) == nil
      assert {:error, :nothing_to_undo} = Mana.Undo.undo(frozen, @other)

      deposited = Ash.update!(frozen, %{amount: 1}, action: :deposit, actor: @me)
      assert Mana.Undo.last(deposited, @me) == nil
    end

    test "within limits how old the change may be" do
      wallet = Ash.create!(ReplayTest.Wallet, %{}, action: :open, actor: @me)
      frozen = Ash.update!(wallet, %{}, action: :freeze, actor: @me)
      assert Mana.Undo.last(frozen, @me, within: {1, :minute})

      [entry | _] = ReplayTest.Entry |> Ash.Query.sort(at: :desc) |> Ash.read!(authorize?: false)
      Mana.Explore.empty_ets(ReplayTest.Entry)

      Ash.Seed.seed!(
        ReplayTest.Entry,
        entry
        |> Map.from_struct()
        |> Map.take([
          :id,
          :subject_type,
          :subject_id,
          :action,
          :verb,
          :actor_id,
          :actor_kind,
          :params,
          :before,
          :after,
          :outcome,
          :summary
        ])
        |> Map.put(:at, DateTime.add(DateTime.utc_now(), -3600, :second))
      )

      assert Mana.Undo.last(frozen, @me, within: {1, :minute}) == nil
    end
  end
end
