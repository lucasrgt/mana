defmodule Mana.Integration do
  @moduledoc """
  A provider slot: the app talks to the slot, an adapter talks to the provider.

      defmodule MyApp.Sms do
        use Mana.Integration, otp_app: :my_app
        @callback send_code(phone :: String.t()) :: :ok | {:error, term}
        def send_code(phone), do: adapter().send_code(phone)
      end

      defmodule MyApp.Sms.Twilio do
        use Mana.Integration.Adapter, slot: MyApp.Sms, env: ["TWILIO_ACCOUNT_SID"]
        ...
      end

      # config/config.exs (dev, test) and config/runtime.exs (prod)
      config :my_app, MyApp.Sms, adapter: MyApp.Sms.Twilio

  `check!/2` runs at boot: every slot resolves to an adapter of that slot, and in
  production no slot may use a fake adapter or miss the adapter's environment.
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)

    quote do
      @doc false
      def __mana_integration__, do: true

      @doc "The configured adapter for this slot."
      def adapter do
        unquote(otp_app)
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:adapter) ||
          raise "#{inspect(__MODULE__)} has no adapter configured for #{inspect(unquote(otp_app))}"
      end
    end
  end

  @doc "Validates the slots' adapters; raises with every problem found."
  def check!(slots, production?) do
    problems = Enum.flat_map(slots, &problems(&1, production?))
    if problems != [], do: raise(ArgumentError, "integrations not ready:\n  " <> Enum.join(problems, "\n  "))
    :ok
  end

  defp problems(slot, production?) do
    adapter = slot.adapter()

    cond do
      not (Code.ensure_loaded?(adapter) and function_exported?(adapter, :__mana_adapter__, 0)) ->
        ["#{inspect(slot)}: #{inspect(adapter)} is not a Mana.Integration.Adapter"]

      adapter.__mana_adapter__().slot != slot ->
        ["#{inspect(slot)}: #{inspect(adapter)} implements #{inspect(adapter.__mana_adapter__().slot)}"]

      production? and adapter.__mana_adapter__().fake? ->
        ["#{inspect(slot)}: fake adapter #{inspect(adapter)} in production"]

      production? ->
        for name <- adapter.__mana_adapter__().env, System.get_env(name) in [nil, ""],
            do: "#{inspect(slot)}: #{name} is not set"

      true ->
        []
    end
  end
end

defmodule Mana.Integration.Adapter do
  @moduledoc "Marks a module as an adapter of a slot; `fake: true` for local adapters."
  defmacro __using__(opts) do
    slot = Keyword.fetch!(opts, :slot)
    env = Keyword.get(opts, :env, [])
    fake? = Keyword.get(opts, :fake, false)

    quote do
      @behaviour unquote(slot)
      @doc false
      def __mana_adapter__,
        do: %{slot: unquote(slot), env: unquote(env), fake?: unquote(fake?)}

      @doc false
      def env!(name) do
        unless Enum.member?(unquote(env), name), do: raise(ArgumentError, "#{name} is not declared by #{inspect(__MODULE__)}")
        System.fetch_env!(name)
      end
    end
  end
end
