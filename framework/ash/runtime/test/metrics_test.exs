defmodule Mana.Runtime.MetricsTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  @name ManaMetricsTest
  @endpoint MetricsTestEndpoint
  @app :mana_metrics_test
  @secret String.duplicate("s", 64)

  setup do
    start_supervised!({Mana.Runtime.Metrics, name: @name, endpoint: @endpoint,
      repo_event: [:metrics_test, :repo, :query], oban: TestOban, queues: [:mail],
      queue_event: [:metrics_test, :queues]})
    Application.put_env(@app, :metrics_token, @secret)
    on_exit(fn -> Application.delete_env(@app, :metrics_token) end)
    :ok
  end

  defp scrape, do: @name |> Mana.Runtime.Metrics.scrape() |> IO.iodata_to_binary()
  defp call(conn), do: Mana.Runtime.MetricsPlug.call(conn, {@app, @name})

  test "queue observations keep declared aggregate labels and distinguish failure from empty" do
    :telemetry.execute([:metrics_test, :queues, :queue], %{age: 170, discarded: 1}, %{queue: "mail", args: "PRIVATE"})
    :telemetry.execute([:metrics_test, :queues, :queue], %{age: 800, discarded: 1}, %{queue: "PRIVATE"})
    :telemetry.execute([:metrics_test, :queues], %{success: 1, timestamp: 100}, %{})
    :telemetry.execute([:metrics_test, :queues], %{success: 0, timestamp: 115}, %{})
    text = scrape()
    assert text =~ "mana_queue_oldest_due_age_seconds{queue=\"mail\"} 170"
    assert text =~ "mana_queue_discarded_present{queue=\"mail\"} 1"
    assert text =~ "mana_queue_observation_success 0"
    assert text =~ "mana_queue_observation_timestamp_seconds 115"
    refute text =~ "PRIVATE"
  end

  test "native telemetry records bounded labels without SQL, URLs, errors or job arguments" do
    canary = "PRIVATE_canary_no_metric_should_contain"
    conn = conn(:get, "/" <> canary) |> put_req_header("authorization", canary)
    conn = %{conn | status: 503, method: canary}
    :telemetry.execute([:bandit, :request, :stop], %{duration: 1_000_000}, %{conn: conn, plug: {@endpoint, []}})
    :telemetry.execute([:metrics_test, :repo, :query], %{total_time: 1_000_000, queue_time: 0},
      %{query: canary, params: [canary], result: {:error, canary}})
    :telemetry.execute([:oban, :job, :exception], %{duration: 1_000_000},
      %{conf: %{name: TestOban}, job: %{queue: canary, args: %{token: canary}}, reason: canary})
    text = scrape()
    refute text =~ canary
    assert text =~ "mana_http_requests_total{method=\"OTHER\",status_class=\"5xx\"} 1"
    assert text =~ "mana_db_queries_total{result=\"error\"} 1"
    assert text =~ "mana_jobs_failures_total{queue=\"other\"} 1"
    assert text =~ "mana_http_duration_microseconds_bucket"
    assert text =~ "mana_db_queue_duration_microseconds_bucket"
  end

  test "other servers/jobs and scrapes are excluded; a crash is counted without error labels" do
    measures = %{duration: 1_000_000, monotonic_time: 1}
    :telemetry.execute([:bandit, :request, :stop], measures, %{conn: conn(:get, "/"), plug: {OtherEndpoint, []}})
    :telemetry.execute([:bandit, :request, :stop], measures, %{conn: conn(:get, "/metrics"), plug: {@endpoint, []}})
    :telemetry.execute([:oban, :job, :stop], measures, %{conf: %{name: OtherOban}, job: %{queue: "mail"}})
    :telemetry.execute([:bandit, :request, :exception], measures, %{plug: {@endpoint, []}, exception: "PRIVATE"})
    text = scrape()
    refute text =~ "mana_http_requests_total{"
    refute text =~ "mana_jobs_finished_total{"
    assert text =~ "mana_http_exceptions_total 1"
    refute text =~ "PRIVATE"
  end

  test "scraping is disabled by default and requires a single dedicated bearer header" do
    assert call(conn(:get, "/metrics?token=" <> @secret)).status == 401
    assert call(conn(:get, "/metrics") |> put_req_header("authorization", "Bearer wrong")).status == 401
    assert call(conn(:post, "/metrics") |> put_req_header("authorization", "Bearer " <> @secret)).status == 405
    duplicate = %{conn(:get, "/metrics") | req_headers: [{"authorization", "Bearer " <> @secret}, {"authorization", "Bearer " <> @secret}]}
    assert call(duplicate).status == 401
    allowed = call(conn(:get, "/metrics") |> put_req_header("authorization", "Bearer " <> @secret))
    assert allowed.status == 200
    assert allowed.halted
    assert get_resp_header(allowed, "cache-control") == ["no-store"]
    assert get_resp_header(allowed, "content-type") == ["text/plain; charset=utf-8"]
    Application.delete_env(@app, :metrics_token)
    assert call(conn(:get, "/metrics")).status == 404
    refute call(conn(:get, "/api/tasks")).halted
  end

  test "histograms retain aggregates, not samples, while scraping is unavailable" do
    conn = %{conn(:get, "/one") | status: 200}
    emit = fn count ->
      for n <- 1..count do
        :telemetry.execute([:bandit, :request, :stop], %{duration: n * 1_000},
          %{conn: %{conn | request_path: "/unbounded-input/#{n}"}, plug: {@endpoint, []}})
      end
    end
    emit.(100)
    before = Peep.storage_size(@name)
    emit.(20_000)
    after_events = Peep.storage_size(@name)
    assert after_events.size <= System.schedulers_online() + 1
    # Peep shards counter cells by scheduler; the histogram has one fixed array.
    # No scrape occurred between these observations. Changing paths and latency
    # samples must not allocate a new series or an accumulating raw-sample table.
    assert after_events.memory <= before.memory + 1_024 * System.schedulers_online()
    assert scrape() =~ "mana_http_requests_total{method=\"GET\",status_class=\"2xx\"} 20100"
  end
end
