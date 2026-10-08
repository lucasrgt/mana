defmodule Mana.Session.Cors do
  import Plug.Conn
  def init(options), do: options

  def call(conn, options) do
    otp_app = Keyword.fetch!(options, :otp_app)

    conn =
      if get_req_header(conn, "origin") == [Application.fetch_env!(otp_app, :web_origin)] do
        conn
        |> put_resp_header(
          "access-control-allow-origin",
          Application.fetch_env!(otp_app, :web_origin)
        )
        |> put_resp_header("vary", "origin")
        |> put_resp_header("access-control-allow-methods", "GET,POST,PATCH,DELETE,OPTIONS")
        |> put_resp_header(
          "access-control-allow-headers",
          Enum.join(
            ["authorization", "content-type", "accept"] ++
              Keyword.get(options, :request_headers, []),
            ","
          )
        )
        |> put_resp_header(
          "access-control-expose-headers",
          Enum.join(["retry-after"] ++ Keyword.get(options, :response_headers, []), ",")
        )
      else
        conn
      end

    if conn.method == "OPTIONS", do: conn |> send_resp(204, "") |> halt(), else: conn
  end
end
