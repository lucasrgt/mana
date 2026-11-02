defmodule SessionTest.Http do
  @moduledoc false
  import Plug.Conn

  alias SessionTest.{ConfirmedUser, Token, User}

  def request(method, path, body \\ nil, bearer \\ nil) do
    conn = Plug.Test.conn(method, path, body)
    if bearer, do: put_req_header(conn, "authorization", "Bearer " <> bearer), else: conn
  end

  def run(conn, plug, options), do: plug.call(conn, plug.init(options))

  def session(conn, action, options \\ []),
    do: run(conn, Mana.Session, [action: action, user: User, token: Token] ++ options)

  def identity(conn, user \\ User),
    do: run(conn, Mana.Session.Identity, otp_app: :mana_session, user: user)

  def body(conn), do: Jason.decode!(conn.resp_body)

  def email, do: "person-#{System.unique_integer([:positive])}@example.test"

  @password "a long enough password"
  def password, do: @password

  def sign_up(email \\ email(), resource \\ User) do
    conn =
      request(:post, "/auth/sign-up", %{
        "email" => email,
        "password" => @password,
        "passwordConfirmation" => @password
      })
      |> run(Mana.Session, action: :sign_up, user: resource, token: Token)

    {email, body(conn)}
  end

  def sign_in(email, password \\ @password, resource \\ User) do
    request(:post, "/auth/sign-in", %{"email" => email, "password" => password})
    |> run(Mana.Session, action: :sign_in, user: resource, token: Token)
  end

  # Registration keeps the account and refuses only the session it would open.
  def unconfirmed(email \\ email()) do
    {:error, %Ash.Error.Forbidden{}} =
      ConfirmedUser
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: email,
        password: @password,
        password_confirmation: @password
      })
      |> Ash.create(authorize?: false)

    Ash.get!(ConfirmedUser, %{email: email}, authorize?: false)
  end
end
