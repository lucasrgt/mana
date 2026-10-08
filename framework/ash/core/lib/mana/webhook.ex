defmodule Mana.Webhook do
  @moduledoc """
  Receives provider webhooks with the raw body intact, so signatures can be
  checked over the exact bytes the provider signed. Mount it in the endpoint
  before `Plug.Parsers`:

      plug Mana.Webhook,
        at: ["webhooks"],
        handlers: %{["stripe", "charges"] => &MyApp.Payments.Webhooks.charge/2}

  A handler gets the raw body and the conn and answers `:ok` or `:ignored`
  (200: done, never resend) or `{:error, reason}` (503: the provider retries
  later). A crash also answers 503. Unknown paths under `at` answer 404.
  """
  import Plug.Conn
  require Logger

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
              result when result in [:ok, :ignored] -> 200
              {:error, reason} -> tap(503, fn _ -> Logger.warning("webhook #{conn.request_path} will be retried: #{inspect(reason)}") end)
            end
          rescue
            error ->
              Logger.error("webhook #{conn.request_path} failed: " <> Exception.format(:error, error, __STACKTRACE__))
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
  def hmac_sha256_valid?(secret, payload, signature) when is_binary(secret) and secret != "" and is_binary(signature) do
    expected = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
    Plug.Crypto.secure_compare(expected, String.downcase(signature))
  end

  def hmac_sha256_valid?(_, _, _), do: false
end
