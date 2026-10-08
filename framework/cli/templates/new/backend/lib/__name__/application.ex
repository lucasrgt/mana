defmodule __Name__.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      __Name__.Repo,
      {Phoenix.PubSub, name: __Name__.PubSub},
      __Name__Web.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __Name__.Supervisor)
  end
end
