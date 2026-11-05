defmodule ManaWeb.Verbs do
  @moduledoc """
  `Mana.Verbs` on a LiveView screen: a control appears only when the record offers
  its verb, says how it should be confirmed, and runs the verb's action.

      <ManaWeb.Verbs.gate :let={verb} record={@booking} verb={:cancel}>
        <.button phx-click="cancel" data-confirm={verb.confirm? && "Cancel the booking?"}>
          Cancel
        </.button>
      </ManaWeb.Verbs.gate>

      def handle_event("cancel", _params, socket) do
        case ManaWeb.Verbs.run(socket.assigns.booking, :cancel, %{}, scope: socket.assigns.scope) do
          {:ok, booking} -> {:noreply, assign(socket, booking: booking)}
          {:error, error} -> {:noreply, put_flash(socket, :error, ManaWeb.Verbs.refusal(error).message)}
        end
      end

  The record must have been read with `:verbs` loaded, for the actor the screen
  serves. What it offers is guidance for the screen; the server still refuses a
  verb whose `when` does not hold and checks the policies on every run, exactly as
  it does for the Flutter adapter.
  """

  use Phoenix.Component

  alias Ash.Resource.Info

  @doc "Whether `record` offers `verb` to the actor it was read for."
  def offered?(%{verbs: verbs}, verb) when is_list(verbs), do: to_string(verb) in verbs

  def offered?(record, _verb),
    do:
      raise(ArgumentError, """
      #{inspect(record.__struct__)} was read without its verbs: load :verbs for the actor \
      the screen serves (Ash.load(record, :verbs, actor: actor), or load: [:verbs] on the read)\
      """)

  @doc """
  How a verb presents itself: its `risk`, whether the screen should ask before
  running it (`confirm?`, always for money and destructive verbs), its `inverse`,
  whether it is `idempotent?`, its `feature` and `describe`.
  """
  def describe(resource, verb) do
    declared = find!(resource, verb)

    %{
      name: declared.name,
      action: Mana.Verbs.action(declared),
      risk: declared.risk,
      confirm?: declared.confirm || declared.risk != :none,
      inverse: declared.inverse,
      idempotent?: declared.idempotent,
      feature: declared.feature,
      describe: declared.describe
    }
  end

  @doc """
  Renders its content only when `record` offers `verb`, passing the verb's
  description (`describe/2`) to `:let`. The content is marked with
  `data-mana-verb="type.verb:<id>"` (in an element with `display: contents`, so
  layout is untouched), the identity a Flutter `VerbGate` gives its control:
  `ManaWeb.Moments` reads what a screen offers from these marks.
  """
  attr :record, :map, required: true
  attr :verb, :atom, required: true
  slot :inner_block, required: true

  def gate(assigns) do
    assigns =
      assign(assigns,
        offered: offered?(assigns.record, assigns.verb),
        described: describe(assigns.record.__struct__, assigns.verb),
        mark: mark(assigns.record, assigns.verb)
      )

    ~H"""
    <span :if={@offered} data-mana-verb={@mark} style="display: contents">
      {render_slot(@inner_block, @described)}
    </span>
    """
  end

  @doc "The identity of `record`'s `verb`: `type.verb:<id>`, as records list what they offer."
  def mark(record, verb) do
    "#{Mana.Entity.type(record.__struct__)}.#{verb}:#{record.id}"
  end

  @doc """
  Runs `verb` on `record` with `input` and Ash options (`actor:`, `tenant:`,
  `scope:`...), through the verb's own update or destroy action. Answers what Ash
  answers; a destroyed record comes back as it was. The run is recorded under the
  verb's feature in `Mana.Feature` when that store is running.
  """
  def run(record, verb, input \\ %{}, opts \\ []) do
    resource = record.__struct__
    action = Info.action(resource, Mana.Verbs.action(find!(resource, verb)))
    started = System.monotonic_time(:microsecond)

    result =
      case action.type do
        :update ->
          record |> Ash.Changeset.for_update(action.name, input, opts) |> Ash.update()

        :destroy ->
          record
          |> Ash.Changeset.for_destroy(action.name, input, opts)
          |> Ash.destroy(return_destroyed?: true)

        type ->
          raise ArgumentError,
                "verb #{verb} of #{inspect(resource)} runs a #{type} action; " <>
                  "run/4 takes the update and destroy verbs a record offers"
      end

    record_feature(resource, action.name, result, started)
    result
  end

  @doc """
  What a refused run should tell the person: the domain error's `code`, `message`
  and `field` when the refusal is one the domain declared (`Mana.Error`), the
  error's message otherwise.
  """
  def refusal(%{errors: errors} = error) do
    Enum.find_value(errors, &domain_error/1) ||
      %{code: nil, message: Exception.message(error), field: nil}
  end

  def refusal(error), do: %{code: nil, message: Exception.message(error), field: nil}

  defp domain_error(%Mana.Error{} = error),
    do: %{code: error.code, message: error.message, field: error.field}

  defp domain_error(%{errors: errors}), do: Enum.find_value(errors, &domain_error/1)
  defp domain_error(_error), do: nil

  defp find!(resource, verb) do
    Enum.find(Mana.Verbs.declared(resource), &(&1.name == verb)) ||
      raise ArgumentError, "#{inspect(resource)} declares no verb #{inspect(verb)}"
  end

  defp record_feature(resource, action, result, started) do
    if feature = Mana.Feature.of_action(resource, action) do
      Mana.Feature.record(feature, status(result), System.monotonic_time(:microsecond) - started)
    end
  end

  defp status({:ok, _record}), do: 200
  defp status({:error, %Ash.Error.Forbidden{}}), do: 403
  defp status({:error, %Ash.Error.Invalid{}}), do: 422
  defp status({:error, _error}), do: 500
end
