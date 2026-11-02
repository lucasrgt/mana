defmodule Mana.WebhookPostgresTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  @moduletag :postgres

  alias PostgresTest.{Harness, Order, Repo}

  setup_all do: Harness.start!()

  setup do
    Harness.reset!()
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted, Map.new(conn.req_headers), body})
      status = Application.get_env(:mana_core, :webhook_test_status, 200)
      Plug.Conn.send_resp(conn, status, "")
    end)

    Application.put_env(:mana_core, :webhooks,
      site: [
        url: "https://site.example/hooks",
        secret: "shh",
        prefix: "x-site",
        req_options: [plug: {Req.Test, __MODULE__}]
      ]
    )

    on_exit(fn ->
      Application.delete_env(:mana_core, :webhooks)
      Application.delete_env(:mana_core, :webhook_test_status)
    end)
  end

  defp jobs, do: Repo.query!("SELECT args, scheduled_at FROM oban_jobs").rows
  defp drain, do: Oban.drain_queue(queue: :webhooks, with_scheduled: true)

  test "an event is delivered once its transaction commits, signed, and never when it rolls back" do
    Ash.DataLayer.transaction([Order], fn ->
      {:ok, _} = Mana.Webhook.deliver(:site, "order.placed", %{"n" => 1})
      Ash.DataLayer.rollback([Order], :undone)
    end)

    assert jobs() == []

    {:ok, _} =
      Ash.DataLayer.transaction([Order], fn ->
        Mana.Webhook.deliver(:site, "order.placed", %{"n" => 2}, id: "order-2")
      end)

    assert %{success: 1} = drain()
    assert_received {:posted, headers, body}

    assert %{"id" => "order-2", "type" => "order.placed", "data" => %{"n" => 2}} =
             Jason.decode!(body)

    assert %{
             "x-site-id" => "order-2",
             "x-site-type" => "order.placed",
             "idempotency-key" => "order-2"
           } =
             headers

    assert "sha256=" <> signature = headers["x-site-signature"]
    assert Mana.Webhook.hmac_sha256_valid?("shh", body, signature)
    refute_received {:posted, _, _}
  end

  test "one id is one event; a refused POST is retried; a date holds it back" do
    at = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, first} = Mana.Webhook.deliver(:site, "doc.effective", %{}, id: "doc-1", at: at)
    {:ok, again} = Mana.Webhook.deliver(:site, "doc.effective", %{}, id: "doc-1", at: at)
    assert again.conflict? and again.id == first.id
    assert [[%{"occurred_at" => occurred}, scheduled]] = jobs()
    assert occurred == DateTime.to_iso8601(at)
    assert DateTime.compare(DateTime.from_naive!(scheduled, "Etc/UTC"), DateTime.utc_now()) == :gt

    Application.put_env(:mana_core, :webhook_test_status, 500)
    assert %{failure: 1} = drain()
    assert_received {:posted, _, _}
  end

  test "an endpoint without a url or secret keeps the event waiting" do
    Application.put_env(:mana_core, :webhooks, site: [url: "https://site.example/hooks"])
    {:ok, _} = Mana.Webhook.deliver(:site, "order.placed", %{})
    assert capture_log(fn -> assert %{snoozed: 1} = drain() end) =~ "site has no url or secret"
    refute_received {:posted, _, _}
  end
end
