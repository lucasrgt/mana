defmodule ManaWebTest.Recipes do
  @moduledoc false
  use Moments.RecipeSet, observe: :observe

  alias ManaCoreTest.Ticket

  recipe :open_ticket, "An open ticket, its owner signed in." do
    ticket("/tickets")
  end

  recipe :open_ticket_on_stale_screen,
         "The same ticket, on a screen that forgets to reload it." do
    ticket("/stale-tickets")
  end

  recipe :closed_ticket, "The ticket after its owner closed it.", observe: :observe do
    parent = context["parent"]
    ticket = Ash.get!(Ticket, parent["inputs"]["ticket"], authorize?: false)
    Ash.update!(ticket, %{}, action: :close, authorize?: false)
    parent
  end

  def observe(launch, _projection) do
    ticket = Ash.get!(Ticket, launch["inputs"]["ticket"], authorize?: false)
    {:ok, %{"ticket" => ticket.id, "status" => to_string(ticket.status)}}
  end

  defp ticket(route) do
    owner = Ash.UUID.generate()
    ticket = Ash.Seed.seed!(Ticket, %{owner_id: owner, status: :open})

    %{
      "route" => "#{route}/#{ticket.id}",
      "account" => %{"id" => owner},
      "inputs" => %{"ticket" => ticket.id}
    }
  end
end

defmodule ManaWebTest.Desk do
  @moduledoc false
  use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

  alias ManaCoreTest.Ticket

  moments do
    route("/tickets")
    field(:ticket, "", max_length: 64)
    field(:status, "open", values: ["open", "closed"])

    moment :close_ticket do
      backend(:open_ticket)
      description("The owner closes an open ticket: it can be reopened, and no longer closed.")
      step(:close, verb: {Ticket, :close}, on: "ticket", until: [:reopenable])
      check(:reopenable, kind: :offered, verb: {Ticket, :reopen}, scope: :step)
      check(:closed_on_screen, kind: :ui_equals, field: :status, equals: "closed")
      check(:not_closable, kind: :not_offered, verb: {Ticket, :close})
      check(:closed, kind: :backend_equals, field: :status, match: :ticket, equals: "closed")
    end

    moment :close_ticket_on_stale_screen do
      backend(:open_ticket_on_stale_screen)

      description(
        "The same journey on a screen that keeps the ticket it read before the verb ran."
      )

      step(:close, verb: {Ticket, :close}, on: "ticket", until: [:reopenable])
      check(:reopenable, kind: :offered, verb: {Ticket, :reopen}, scope: :step)
      check(:not_closable, kind: :not_offered, verb: {Ticket, :close})
      check(:closed, kind: :backend_equals, field: :status, match: :ticket, equals: "closed")
    end

    moment :closed_ticket do
      from(:close_ticket)
      backend(:closed_ticket)
      description("A closed ticket, prepared on its parent's launch: only reopen is offered.")
      check(:reopenable, kind: :offered, verb: {Ticket, :reopen})
      check(:not_closable, kind: :not_offered, verb: {Ticket, :close})
    end

    moment :rename_ticket do
      backend(:open_ticket)
      description("The owner types a new title, a gesture LiveView Moments do not run yet.")
      step(:title, fill: "ticket-title", from: "ticket")
      check(:closable, kind: :offered, verb: {Ticket, :close})
    end

    moment :ticket_on_the_phone do
      backend(:open_ticket)
      platforms([:native])
      description("Only on the phone.")
      check(:closable, kind: :offered, verb: {Ticket, :close})
    end
  end
end

defmodule ManaWebTest.TicketLive do
  @moduledoc false
  use Phoenix.LiveView

  alias ManaCoreTest.Ticket
  alias ManaWeb.Verbs

  @impl true
  def mount(%{"id" => id}, session, socket) do
    actor = %{id: session["owner_id"]}
    stale? = socket.assigns.live_action == :stale
    {:ok, assign(socket, actor: actor, stale?: stale?, ticket: load(id, actor))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <span data-moment-field="status">{@ticket.status}</span>
    <Verbs.gate record={@ticket} verb={:close}>
      <button phx-click="run" phx-value-verb="close">Close</button>
    </Verbs.gate>
    <Verbs.gate record={@ticket} verb={:reopen}>
      <button phx-click="run" phx-value-verb="reopen">Reopen</button>
    </Verbs.gate>
    """
  end

  @impl true
  def handle_event("run", %{"verb" => verb}, socket) do
    %{ticket: ticket, actor: actor} = socket.assigns
    {:ok, _ticket} = Verbs.run(ticket, String.to_existing_atom(verb), %{}, actor: actor)

    # The bug a Moment must catch: the stale screen keeps what it read before the verb ran.
    if socket.assigns.stale?,
      do: {:noreply, socket},
      else: {:noreply, assign(socket, ticket: load(ticket.id, actor))}
  end

  defp load(id, actor), do: Ash.get!(Ticket, id, load: [:verbs], actor: actor)
end

defmodule ManaWebTest.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
  end

  scope "/" do
    pipe_through(:browser)
    live("/tickets/:id", ManaWebTest.TicketLive, :show)
    live("/stale-tickets/:id", ManaWebTest.TicketLive, :stale)
  end
end

defmodule ManaWebTest.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :mana_web

  @session [store: :cookie, key: "_mana_web_test", signing_salt: "mana-web-test"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]])
  plug(Plug.Session, @session)
  plug(ManaWebTest.Router)
end
