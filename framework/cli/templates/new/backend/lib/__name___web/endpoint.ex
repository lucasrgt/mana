defmodule __Name__Web.Cors do
  @moduledoc "Lets the web build of the app (its origins in `web_origins`) call the API."
  import Plug.Conn

  def init(options), do: options

  def call(conn, _options) do
    origin = conn |> get_req_header("origin") |> List.first()

    conn =
      if origin && origin in Application.get_env(:__name__, :web_origins, []) do
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-headers", "authorization, content-type")
        |> put_resp_header("access-control-allow-methods", "GET, POST, PATCH, DELETE, OPTIONS")
        |> put_resp_header("vary", "origin")
      else
        conn
      end

    if conn.method == "OPTIONS", do: conn |> send_resp(204, "") |> halt(), else: conn
  end
end

defmodule __Name__Web.JsonApi do
  use AshJsonApi.Router, domains: [__Name__.Notes], open_api: "/open_api"
end

defmodule __Name__Web.Router do
  @moduledoc "Health, the Moments recipes (development only) and the JSON:API."
  use Plug.Router

  plug :match
  plug :dispatch

  get "/healthz" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{service: "__dash__-api"}))
  end

  if Application.compile_env(:__name__, :moment_recipes?, false) do
    forward "/__moments",
      to: Moments.Recipes,
      init_opts: [token: {Application, :get_env, [:__name__, :moments_recipe_token]}, recipes: __Name__.Moments.recipes()]
  end

  forward "/api", to: __Name__Web.JsonApi

  match _ do
    send_resp(conn, 404, "")
  end
end

defmodule __Name__Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :__name__

  plug __Name__Web.Cors
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
  plug __Name__Web.Router
end
