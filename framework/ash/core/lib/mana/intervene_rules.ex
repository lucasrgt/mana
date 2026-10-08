defmodule Mana.Intervene.Rules do
  @moduledoc """
  Server-side interventions on a running development app, without editing it:

    * `latency:<path glob>=<ms>` — matching API requests wait that long
      (`Mana.Intervene.Plug`), to see loading states and timeouts;
    * `fn:<Module.fun>=raise|nil|<json>` — a function marked with
      `defexample` (`Mana.Examples`) raises or answers that value instead of
      running, to see what its callers do with it.

  Rules come from `MANA_INTERVENE` (`;`-separated) or `set/1`, and apply only
  with `config :mana_core, :interventions, true` (development).
  """

  @key {__MODULE__, :rules}

  def enabled?, do: Application.get_env(:mana_core, :interventions, false) == true

  @doc "Replaces the rules (`[]` lifts them)."
  def set(rules) do
    :persistent_term.put(@key, Enum.flat_map(rules, &parse/1))
    :ok
  end

  def rules do
    case :persistent_term.get(@key, nil) do
      nil ->
        parsed = (System.get_env("MANA_INTERVENE") || "") |> String.split(";", trim: true) |> Enum.flat_map(&parse/1)
        :persistent_term.put(@key, parsed)
        parsed

      rules ->
        rules
    end
  end

  @doc false
  def parse(rule) do
    case String.split(String.trim(rule), "=", parts: 2) do
      ["latency:" <> glob, ms] ->
        case Integer.parse(ms) do
          {n, ""} when n >= 0 -> [{:latency, compile(glob), n}]
          _ -> []
        end

      ["fn:" <> name, value] ->
        [{:fn, name, value(value)}]

      _ ->
        []
    end
  end

  defp value("raise"), do: :raise
  defp value("nil"), do: {:return, nil}

  defp value(json) do
    case Jason.decode(json) do
      {:ok, v} -> {:return, v}
      _ -> {:return, json}
    end
  end

  defp compile(glob) do
    pattern =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.compile!("^" <> pattern <> "$")
  end

  @doc "The milliseconds a request to `path` waits, or 0."
  def latency(path) do
    if enabled?(), do: Enum.find_value(rules(), 0, &match_latency(&1, path)), else: 0
  end

  defp match_latency({:latency, regex, ms}, path), do: if(Regex.match?(regex, path), do: ms)
  defp match_latency(_, _), do: nil

  @doc "The override for `module.name`, or `:none`."
  def override(module, name) do
    target = "#{inspect(module)}.#{name}"

    if enabled?() do
      Enum.find_value(rules(), :none, fn
        {:fn, ^target, action} -> action
        _ -> nil
      end)
    else
      :none
    end
  end
end

if Code.ensure_loaded?(Plug.Conn) do
  defmodule Mana.Intervene.Plug do
    @moduledoc "Applies `latency:` interventions (`Mana.Intervene.Rules`); mount it in the development endpoint."
    def init(opts), do: opts

    def call(conn, _opts) do
      case Mana.Intervene.Rules.latency(conn.request_path) do
        0 ->
          conn

        ms ->
          Process.sleep(ms)
          conn
      end
    end
  end
end
