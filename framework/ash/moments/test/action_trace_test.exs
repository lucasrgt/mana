defmodule Moments.ActionTraceTest do
  use ExUnit.Case, async: true
  alias Moments.ActionTrace, as: Trace

  defmodule Item do
    use Ash.Resource,
      domain: Moments.ActionTraceTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false

    attributes do
      uuid_primary_key(:id)
      attribute(:value, :string, public?: true)
    end

    actions do
      defaults([:read, create: [:value]])

      action :reject do
        run(fn _, _ -> {:error, "private-error-payload"} end)
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Moments.ActionTraceTest.Item)
    end
  end

  setup do
    on_exit(fn -> Trace.discard() end)
    :ok
  end

  defp id, do: Ash.UUID.generate()
  defp read, do: Ash.read!(Item, authorize?: false, tracer: [Trace])

  test "native Ash metadata is reduced before retention and observation does not imply authorization" do
    gesture = id()
    Trace.begin_request(gesture)
    Ash.create!(Item, %{value: "private-argument"}, authorize?: false, tracer: [Trace])
    read()
    receipt = Trace.finish_request()
    assert receipt.gesture == gesture
    assert receipt.coverage == "not-established"
    assert Enum.any?(receipt.actions, &(&1.action == "create" and &1.resource == inspect(Item)))
    assert Enum.any?(receipt.actions, &(&1.authorization_requested == false))
    refute String.contains?(Jason.encode!(receipt), "private-argument")
    refute Trace.trace_type?(:action)
  end

  test "returned errors are recorded without messages or stacktraces" do
    Trace.begin_request(id())

    assert {:error, _} =
             Item
             |> Ash.ActionInput.for_action(:reject, %{})
             |> Ash.run_action(tracer: [Trace], authorize?: false)

    receipt = Trace.finish_request()
    assert Enum.any?(receipt.actions, &(&1.action == "reject" and &1.outcome == "error-reported"))
    refute String.contains?(Jason.encode!(receipt), "private-error-payload")
  end

  test "native bulk paths identify the declared action without pretending to prove each row" do
    start_supervised!({Moments.ActionTrace.Telemetry, id: make_ref(), domains: [Domain]})
    Trace.begin_request(id())

    result =
      Ash.bulk_create([%{value: "first"}, %{value: "second"}], Item, :create,
        authorize?: false,
        tracer: [Trace],
        return_errors?: true,
        return_records?: true
      )

    assert result.status == :success
    receipt = Trace.finish_request()
    assert Enum.any?(receipt.actions, &(&1.action == "create" and &1.kind == "bulk_create"))
    assert receipt.coverage == "not-established"
    assert Enum.count(receipt.actions, &(&1.kind == "bulk_create")) == 1

    Trace.begin_request(id())

    result =
      Ash.bulk_create([%{value: "third"}], Item, :create,
        authorize?: false,
        return_errors?: true,
        return_records?: true
      )

    assert result.status == :success
    receipt = Trace.finish_request()
    assert Enum.any?(receipt.actions, &(&1.action == "create" and &1.kind == "bulk_create"))
  end

  test "concurrent requests never share a table and native Ash task context retains ownership" do
    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          gesture = id()
          Trace.begin_request(gesture)
          read()
          task = Ash.ProcessHelpers.async(fn -> read() end, tracer: [Trace])
          Task.await(task)
          {gesture, Trace.finish_request()}
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.all?(results, fn {gesture, receipt} ->
             receipt.gesture == gesture and length(receipt.actions) == 2
           end)

    assert results |> Enum.map(fn {_, r} -> r.request end) |> Enum.uniq() |> length() == 8
  end

  test "a request names the records it changed, by field name only, and nothing outside a request" do
    assert Trace.annotate_change(%{resource: Some.Thing, subject: "id-1", action: :accept, outcome: "done", fields: [:status]}) == :ok
    Trace.begin_request(id())
    Trace.annotate_change(%{resource: Some.Thing, subject: "id-1", action: :accept, outcome: "done", fields: [:status, :accepted_at]})
    Enum.each(1..20, fn n -> Trace.annotate_change(%{resource: Some.Thing, subject: "id-#{n}", action: :touch, outcome: "failed", fields: []}) end)
    receipt = Trace.finish_request()
    assert receipt.version == 3
    assert [%{resource: "Some.Thing", subject: "id-1", action: "accept", outcome: "done", fields: ["status", "accepted_at"]} | _] = receipt.changes
    assert length(receipt.changes) == 16

    Trace.begin_request(id())
    assert %{version: 2} = Trace.finish_request()
    refute Map.has_key?(Trace.finish_request() || %{}, :changes)
  end

  test "receipts are bounded and work after request closure cannot extend them" do
    Trace.begin_request(id())
    context = Trace.get_span_context()
    Enum.each(1..25, fn _ -> read() end)
    receipt = Trace.finish_request()
    assert receipt.truncated
    assert length(receipt.actions) == 16

    task =
      Task.async(fn ->
        Trace.set_span_context(context)
        read()
        :ok
      end)

    assert Task.await(task) == :ok
    assert Trace.finish_request() == nil
  end

  test "telemetry registration is supervised and ambiguous identities do not become evidence" do
    handler_id = make_ref()
    child = start_supervised!({Moments.ActionTrace.Telemetry, id: handler_id, domains: [Domain]})
    event = [:ash, Ash.Domain.Info.short_name(Domain), :bulk_update, :stop]

    assert Enum.any?(
             :telemetry.list_handlers(event),
             &(&1.id == {Moments.ActionTrace.Telemetry, handler_id})
           )

    Trace.begin_request(id())

    Moments.ActionTrace.Telemetry.handle_event(
      event,
      %{},
      %{resource_short_name: :ambiguous, action: :read},
      %{{Ash.Domain.Info.short_name(Domain), :ambiguous} => nil}
    )

    assert Trace.finish_request().actions == []
    GenServer.stop(child)

    refute Enum.any?(
             :telemetry.list_handlers(event),
             &(&1.id == {Moments.ActionTrace.Telemetry, handler_id})
           )
  end

  test "arbitrary actor, tenant, input and error metadata never enters retained events" do
    Trace.begin_request(id())
    Trace.start_span(:action, "private-span-name")

    Trace.set_metadata(:action, %{
      resource: Item,
      action: :read,
      actor: "private-actor",
      tenant: "private-tenant",
      input: "private-input"
    })

    Trace.set_error("private-error", stacktrace: ["private-stack"])
    Trace.stop_span()
    encoded = Trace.finish_request() |> Jason.encode!()
    refute String.contains?(encoded, "private-")
  end

  test "request profile aggregates only attributed Repo events, including native Ash task context" do
    event = [:action_trace_test, :repo, :query]
    start_supervised!({Moments.ActionTrace.Telemetry,
      id: make_ref(), domains: [Domain], repo_event: event})
    Trace.begin_request(id())
    read()
    native = System.convert_time_unit(1200, :microsecond, :native)
    measurements = %{total_time: native, query_time: native, queue_time: 0, decode_time: 0}
    :telemetry.execute([:other_repo, :query], measurements, %{})
    :telemetry.execute(event, measurements, %{query: "private-sql", params: ["private-params"]})
    task = Ash.ProcessHelpers.async(fn ->
      :telemetry.execute(event, measurements, %{result: {:error, "private-error"}})
    end, tracer: [Trace])
    Task.await(task)
    receipt = Trace.finish_request()
    assert receipt.version == 2
    assert receipt.profile.requestDurationUs >= 0
    assert receipt.profile.database.queries == 2
    assert receipt.profile.database.totalUs == 2400
    assert Enum.all?(receipt.actions, &(is_integer(&1.durationUs) and &1.durationUs >= 0))
    refute String.contains?(Jason.encode!(receipt), "private-")
    Trace.begin_request(id())
    assert Trace.finish_request().profile.database == %{status: "not-observed"}
  end
end
