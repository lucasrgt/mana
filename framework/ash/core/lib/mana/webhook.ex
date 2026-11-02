defmodule Mana.Webhook do
  @moduledoc """
  Webhooks both ways.

  ## Receiving

  Provider webhooks arrive with the raw body intact, so signatures can be
  checked over the exact bytes the provider signed. Mount it in the endpoint
  before `Plug.Parsers`:

      plug Mana.Webhook,
        at: ["webhooks"],
        handlers: %{["stripe", "charges"] => &MyApp.Payments.Webhooks.charge/2}

  A handler gets the raw body and the conn and answers `:ok` or `:ignored`
  (200: done, never resend) or `{:error, reason}` (503: the provider retries
  later). A crash also answers 503. Unknown paths under `at` answer 404.

  ## Sending

      Mana.Webhook.deliver(:site, "document.effective", %{id: doc.id, version: doc.version},
        id: "document-\#{doc.id}", at: doc.effective_at)

  tells an endpoint of the app's configuration that something happened:

      config :mana_core, :webhooks,
        site: [url: "https://example.org/hooks", secret: "...", prefix: "x-example"]

  `deliver/4` inserts an Oban job (`Mana.Webhook.Delivery`, queue
  `:webhooks`): inside an action or a transaction it commits with the change
  or not at all, and survives a crash after the commit. The job POSTs
  `{"id", "type", "occurred_at", "data"}` as JSON with `<prefix>-id`,
  `<prefix>-type` and `<prefix>-signature: sha256=<hex HMAC-SHA256 of the
  body>` (`prefix` defaults to `webhook`; the receiver checks it with
  `hmac_sha256_valid?/3`) and `idempotency-key` set to the id, and retries
  with backoff until a 2xx (10 attempts). While the endpoint has no `url`
  or `secret` the event waits, retried hourly. The event id (`id:`, a fresh
  UUID by default) is the event: the receiver drops a redelivery by it, and
  a second `deliver` with the same id inserts nothing. `at:` delivers no
  earlier than that time (and is its `occurred_at`, unless `occurred_at:`).
  Delivery is at least once: a POST whose answer was lost is sent again.
  `req_options:` in the endpoint's configuration go to `Req` (a test plug).
  """
  import Plug.Conn
  require Logger
  alias Mana.Webhook.Delivery

  @compile {:no_warn_undefined, [Delivery, Oban]}

  @max_bytes 1_000_000

  def init(opts), do: Map.new(opts)

  def call(%{path_info: path} = conn, %{at: at, handlers: handlers}) do
    with true <- List.starts_with?(path, at),
         rest = Enum.drop(path, length(at)),
         "POST" <- conn.method do
      case handlers[rest] do
        nil -> conn |> send_resp(404, "") |> halt()
        handler -> conn |> handle(handler) |> halt()
      end
    else
      _ -> conn
    end
  end

  defp handle(conn, handler) do
    case read_body(conn, length: @max_bytes) do
      {:ok, body, conn} ->
        status =
          try do
            case handler.(body, conn) do
              result when result in [:ok, :ignored] ->
                200

              {:error, reason} ->
                tap(503, fn _ ->
                  Logger.warning(
                    "webhook #{conn.request_path} will be retried: #{inspect(reason)}"
                  )
                end)
            end
          rescue
            error ->
              Logger.error(
                "webhook #{conn.request_path} failed: " <>
                  Exception.format(:error, error, __STACKTRACE__)
              )

              503
          end

        send_resp(conn, status, "")

      {:more, _, conn} ->
        send_resp(conn, 413, "")

      {:error, _} ->
        send_resp(conn, 400, "")
    end
  end

  @doc "Constant-time comparison of a hex HMAC-SHA256 of `payload` against `signature`, case-insensitive."
  def hmac_sha256_valid?(secret, payload, signature)
      when is_binary(secret) and secret != "" and is_binary(signature) do
    Plug.Crypto.secure_compare(hmac_sha256(secret, payload), String.downcase(signature))
  end

  def hmac_sha256_valid?(_, _, _), do: false

  @doc "The HMAC-SHA256 of `payload` under `secret`, hex, as `hmac_sha256_valid?/3` checks it."
  def hmac_sha256(secret, payload),
    do: :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

  @doc """
  Inserts the delivery of event `type` with `data` to endpoint `name` (see
  "Sending"); answers `{:ok, job}` (a job already there for the id comes
  back with `conflict?: true`) or `{:error, changeset}`. Options: `id`, `at`,
  `occurred_at`.
  """
  def deliver(name, type, data, opts \\ []) when is_atom(name) and is_binary(type) do
    at = opts[:at]

    %{
      "endpoint" => to_string(name),
      "id" => opts[:id] || Ash.UUID.generate(),
      "type" => type,
      "occurred_at" => DateTime.to_iso8601(opts[:occurred_at] || at || DateTime.utc_now()),
      "data" => data
    }
    |> Delivery.new(if(at, do: [scheduled_at: at], else: []))
    |> Oban.insert()
  end
end

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Webhook.Delivery do
    @moduledoc false
    use Oban.Worker,
      queue: :webhooks,
      max_attempts: 10,
      unique: [period: :infinity, keys: [:endpoint, :id]]

    require Logger

    @impl true
    def backoff(%Oban.Job{attempt: attempt}), do: min(3600, 30 * Integer.pow(2, attempt - 1))

    @impl true
    def perform(%Oban.Job{args: %{"endpoint" => name} = args}) do
      config =
        Enum.find_value(Application.get_env(:mana_core, :webhooks, []), [], fn {key, config} ->
          if to_string(key) == name, do: config
        end)

      with url when is_binary(url) and url != "" <- config[:url],
           secret when is_binary(secret) and secret != "" <- config[:secret] do
        post(url, secret, config, args)
      else
        _ ->
          Logger.warning("webhook endpoint #{name} has no url or secret; the event waits")
          {:snooze, 3600}
      end
    end

    defp post(url, secret, config, args) do
      prefix = config[:prefix] || "webhook"
      body = Jason.encode!(Map.take(args, ["id", "type", "occurred_at", "data"]))

      [
        url: url,
        body: body,
        retry: false,
        headers: [
          {"content-type", "application/json"},
          {"idempotency-key", args["id"]},
          {"#{prefix}-id", args["id"]},
          {"#{prefix}-type", args["type"]},
          {"#{prefix}-signature", "sha256=" <> Mana.Webhook.hmac_sha256(secret, body)}
        ]
      ]
      |> Keyword.merge(config[:req_options] || [])
      |> Req.post()
      |> case do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
        {:error, error} -> {:error, Exception.message(error)}
      end
    end
  end
end
