defmodule Moments.ActionTrace.Plug do
  @moduledoc """
  Development-only HTTP wiring for `Moments.ActionTrace`: a request carrying
  a gesture id in `x-mana-gesture` is traced, and its receipt goes back in
  `x-mana-actions` (omitted when it would not fit a header). Mount it in the
  endpoint only when tracing is enabled, with `config :ash, :tracer,
  [Moments.ActionTrace]` and `Moments.ActionTrace.Telemetry` supervised, and
  let CORS accept the first header and expose the second.
  """
  import Plug.Conn

  @gesture ~r/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/

  def init(options), do: options

  def call(conn, _options) do
    Moments.ActionTrace.discard()

    case get_req_header(conn, "x-mana-gesture") do
      [id] when byte_size(id) == 36 ->
        if Regex.match?(@gesture, id) do
          Moments.ActionTrace.begin_request(id)

          register_before_send(conn, fn conn ->
            encoded = Moments.ActionTrace.finish_request() |> Jason.encode!() |> Base.url_encode64(padding: false)
            if byte_size(encoded) <= 7000, do: put_resp_header(conn, "x-mana-actions", encoded), else: conn
          end)
        else
          conn
        end

      _ ->
        conn
    end
  end
end
