A team member signed in on an iPhone does not see the team's own place on
the travelers' map, although the public points show. The team's places are
shown only to test accounts, and sign-up marks an account as a test account
when its email matches the team's addresses (`:test_account_emails`). This
account was opened before that mark existed (or moved to a team email
later), so it is not marked.

Every account with a team email must be a test account, the existing ones
included. Declare it as a reconciliation rule on the user
(`Mana.Reconcile`), so that `Mana.Reconcile.observe(Hostpoint.Accounts.User,
apply: true)` marks the accounts that are not yet marked.
