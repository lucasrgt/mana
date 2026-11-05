defmodule Mop.Access do
  @moduledoc """
  A permission matrix per resource and action: role defaults refined by per-user overrides.

  A catalog lists one policy per governed resource as `{resource, applicable, defaults}`:
  `applicable` are the actions the resource exposes and `defaults` pairs each role with the
  actions it gets, as `[{role, [action]}]`. A user's overrides are `{resource, action, effect}`
  rows, with `effect` either `:allow` or `:deny`, stored only where the user differs from the
  role default.

  Every function is total: a malformed catalog or override row closes access instead of
  raising. An override whose effect is neither `:allow` nor absent denies.

  The rules, each one a law in `test/laws`:

    * a superuser may do everything;
    * a resource with no policy is closed to everyone else;
    * an action the resource does not expose is never allowed, whatever the overrides say;
    * otherwise an override decides, and without one the role default does;
    * the actions offered to a screen are exactly the applicable ones `allowed?/6` answers yes to.
  """

  @doc "Whether the user may perform `action` on `resource`."
  def allowed?(true, _role, _overrides, _policies, _resource, _action), do: true

  def allowed?(false, role, overrides, policies, resource, action) do
    case policy(policies, resource) do
      {applicable, defaults} ->
        member?(applicable, action) and cell?(role, overrides, defaults, resource, action)

      nil ->
        false
    end
  end

  @doc "The actions of `resource` a screen should offer the user, in the policy's order."
  def offered(superuser?, role, overrides, policies, resource) do
    case policy(policies, resource) do
      {applicable, _defaults} ->
        keep_allowed(applicable, superuser?, role, overrides, policies, resource)

      nil ->
        []
    end
  end

  @doc """
  The sparse overrides that give a non-superuser of `role` exactly the `wanted` actions on
  `resource`: one row per applicable action where the wish differs from the role default.
  """
  def reconcile(role, policies, resource, wanted) do
    case policy(policies, resource) do
      {applicable, defaults} -> rows(applicable, defaults_for(defaults, role), resource, wanted)
      nil -> []
    end
  end

  def policy([{resource, applicable, defaults} | _], resource), do: {applicable, defaults}
  def policy([_ | policies], resource), do: policy(policies, resource)
  def policy(_policies, _resource), do: nil

  def override([{resource, action, effect} | _], resource, action), do: effect
  def override([_ | overrides], resource, action), do: override(overrides, resource, action)
  def override(_overrides, _resource, _action), do: nil

  def defaults_for([{role, actions} | _], role), do: actions
  def defaults_for([_ | defaults], role), do: defaults_for(defaults, role)
  def defaults_for(_defaults, _role), do: []

  def member?([value | _], value), do: true
  def member?([_ | values], value), do: member?(values, value)
  def member?(_values, _value), do: false

  defp cell?(role, overrides, defaults, resource, action) do
    case override(overrides, resource, action) do
      :allow -> true
      nil -> member?(defaults_for(defaults, role), action)
      _deny -> false
    end
  end

  defp keep_allowed([action | actions], superuser?, role, overrides, policies, resource) do
    rest = keep_allowed(actions, superuser?, role, overrides, policies, resource)

    if allowed?(superuser?, role, overrides, policies, resource, action),
      do: [action | rest],
      else: rest
  end

  defp keep_allowed(_actions, _superuser?, _role, _overrides, _policies, _resource), do: []

  defp rows([action | actions], defaults, resource, wanted) do
    rest = rows(actions, defaults, resource, wanted)

    case {member?(wanted, action), member?(defaults, action)} do
      {same, same} -> rest
      {true, false} -> [{resource, action, :allow} | rest]
      {false, true} -> [{resource, action, :deny} | rest]
    end
  end

  defp rows(_actions, _defaults, _resource, _wanted), do: []
end
