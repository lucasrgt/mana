defmodule ManaLint.Check.AshEffectInTransactionHookTest do
  use Credo.Test.Case

  alias ManaLint.Check.AshEffectInTransactionHook, as: Check

  test "an effect in a function given to after_action" do
    """
    defmodule App.Refund do
      use Ash.Resource.Change
      alias App.Payments.Stripe

      def change(changeset, _, _) do
        Ash.Changeset.after_action(changeset, fn _, charge ->
          Stripe.refund(charge.payment_id)
          {:ok, charge}
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(fn issue ->
      assert issue.trigger == "Stripe.refund"
      assert issue.message =~ "inside `after_action`"
    end)
  end

  test "a piped before_action through an aliased Changeset" do
    """
    defmodule App.Upload do
      alias Ash.Changeset

      def discard(changeset) do
        changeset
        |> Changeset.before_action(fn changeset ->
          Mana.Storage.delete(changeset.data.key)
          changeset
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(&assert(&1.trigger == "Mana.Storage.delete"))
  end

  test "a local capture is followed into its function" do
    """
    defmodule App.Cancel do
      def change(changeset, _, _) do
        Ash.Changeset.before_action(changeset, &release(&1, changeset.data))
      end

      defp release(changeset, booking) do
        App.Payments.Stripe.refund(booking.payment_id)
        changeset
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(fn issue ->
      assert issue.trigger == "release"
      assert issue.message =~ "`Cancel.release` reaches an external effect (Stripe.refund)"
    end)
  end

  test "calls are followed across the project's modules" do
    [
      """
      defmodule App.Cancel do
        alias App.Billing

        def change(changeset, _, _) do
          Ash.Changeset.after_action(changeset, &settle/2)
        end

        defp settle(_, booking) do
          :ok = Billing.release_on_cancel(booking)
          {:ok, booking}
        end
      end
      """,
      """
      defmodule App.Billing do
        alias App.Payments.Stripe

        def release_on_cancel(booking), do: refund(booking.payment_id)

        defp refund(id), do: Stripe.refund(id)
      end
      """
    ]
    |> to_source_files()
    |> run_check(Check)
    |> assert_issue(fn issue ->
      assert issue.trigger == "settle"
      assert issue.message =~ "Billing.release_on_cancel → Billing.refund → Stripe.refund"
    end)
  end

  test "a broadcast in a change/3 body and an announce in a DSL after_action" do
    """
    defmodule App.Touch do
      use Ash.Resource.Change

      def change(changeset, _, _) do
        Phoenix.PubSub.broadcast(App.PubSub, "t", :touched)
        changeset
      end
    end

    defmodule App.Thing do
      use Ash.Resource

      actions do
        update :touch do
          change after_action(fn _, record, _ ->
            Mana.Entity.announce(record)
            {:ok, record}
          end)
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issues(fn issues ->
      assert Enum.map(issues, & &1.trigger) |> Enum.sort() ==
               ["Mana.Entity.announce", "Phoenix.PubSub.broadcast"]

      assert Enum.find(issues, &(&1.trigger == "Phoenix.PubSub.broadcast")).message =~
               "in `change/3`"
    end)
  end

  test "a broadcast in after_transaction, but not other effects there" do
    """
    defmodule App.Publish do
      def change(changeset, _, _) do
        Ash.Changeset.after_transaction(changeset, fn _, result ->
          App.Payments.Stripe.capture("pi")
          MyAppWeb.Endpoint.broadcast("t", "changed", %{})
          result
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(fn issue ->
      assert issue.trigger == "MyAppWeb.Endpoint.broadcast"
      assert issue.message =~ "after_transaction"
    end)
  end

  test "a transaction opened by hand, and Mana.Privacy.erase as an effect" do
    """
    defmodule App.Expire do
      def run(charge) do
        Ash.transact(App.Charge, fn ->
          App.Payments.Stripe.expire_checkout(charge.checkout_id)
          App.Repo.transaction(fn -> Mana.Privacy.erase([App.Accounts], charge.user_id) end)
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.trigger) |> Enum.sort() ==
               ["App.Payments.Stripe.expire_checkout", "Mana.Privacy.erase"]

      assert Enum.all?(issues, &(&1.message =~ "in its transaction"))
    end)
  end

  test "before_transaction, Oban.insert and notifiers are left alone" do
    """
    defmodule App.Checkout do
      use Ash.Resource.Change

      def change(changeset, _, _) do
        changeset
        |> Ash.Changeset.before_transaction(fn changeset ->
          App.Payments.Stripe.create_checkout(%{})
          changeset
        end)
        |> Ash.Changeset.after_action(fn _, record ->
          {:ok, _} = Oban.insert(App.Deliver.new(%{id: record.id}))
          {:ok, record}
        end)
      end
    end

    defmodule App.Notifier do
      use Ash.Notifier

      def notify(%{data: record}) do
        Phoenix.PubSub.broadcast(App.PubSub, "t", record)
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end

  test "a change body that only registers deferred effects is not an effect" do
    """
    defmodule App.Charge do
      use Ash.Resource.Change

      def change(changeset, _, _), do: charge_first(changeset)

      defp charge_first(changeset) do
        Ash.Changeset.before_transaction(changeset, fn changeset ->
          App.Payments.Stripe.capture(changeset.data.id)
          changeset
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end

  test "Stripe reads, Req.get and pure helpers are not effects" do
    """
    defmodule App.Check do
      def change(changeset, _, _) do
        Ash.Changeset.before_action(changeset, fn changeset ->
          {:ok, _} = App.Payments.Stripe.get_payment("pi")
          Req.get!("https://example.com")
          Ash.Changeset.force_change_attribute(changeset, :total, App.Money.total(changeset))
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end

  test "effects are configurable, and following calls can be switched off" do
    source = """
    defmodule App.Note do
      def change(changeset, _, _) do
        Ash.Changeset.after_action(changeset, fn _, record ->
          :telemetry.execute([:app, :noted], %{}, %{})
          {:ok, notify(record)}
        end)
      end

      defp notify(record), do: App.Sms.send(record)
    end
    """

    source
    |> to_source_file()
    |> run_check(Check, effects: [":telemetry.execute", App.Sms])
    |> assert_issues(&assert(length(&1) == 2))

    source
    |> to_source_file()
    |> run_check(Check, effects: [App.Sms], follow_calls: false)
    |> refute_issues()
  end
end
