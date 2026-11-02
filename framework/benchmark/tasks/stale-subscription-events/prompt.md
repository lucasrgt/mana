Stripe subscription events and erasure.

1. A host's plan and a partner's ad follow any subscription event for that
   host or ad, without checking that it is about the subscription stored
   for them. A second subscription is also possible: the plan checkout opens
   for a host who already subscribes, and a lapsed ad can be paid again
   while its old subscription lives on. So a late
   `customer.subscription.deleted` of an old subscription drops a host back
   to Go, or takes a paying partner's ad off the air. Only the stored
   subscription may change a plan or an ad. A host with an active
   subscription who opens the plan checkout gets the error code
   `payments.plan_already_subscribed`. Paying a lapsed ad again cancels its
   old subscription in Stripe first.
2. Fulfilling a person's erasure leaves their paid subscriptions running:
   an erased host is still billed, and an erased partner's ads stay on the
   air. Erasure must cancel their subscriptions in Stripe (add
   `cancel_subscription/1` to the Stripe adapter and its fake, which
   records the call as `:cancel_subscription`), mark the host's plan
   canceled, and take the partner's ads off the air (`:lapsed`).
