Hosts get the Pro plan free for `host_trial_months` from the plans' launch
or from their sign-up. We want to be able to say instead "Pro is free for
everyone until 1 February", whenever each host signed up.

Add an optional end for every trial: `host_trial_ends_at` in the
`Hostpoint.Payments` application config (a `DateTime`, read from the
`HOST_TRIAL_ENDS_AT` environment variable in ISO 8601, empty meaning unset),
also exposed as a knob of the same name so the operators can change it.
When set, every host without a subscription is on the trial (`access:
:trial`, plan Pro, `trial_ends_at` that day) until it passes; after it,
their access is `:expired` and their places leave the map, while
subscribers keep theirs. When unset, trials work as today. The lab
(`tools/hostpoint lab`) must pass `HOST_TRIAL_ENDS_AT` through like the
other payment switches.
