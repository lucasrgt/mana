Three payment bugs. They are latent today because checkout through the
platform is switched off in production, and they break when it is switched
on.

1. With platform checkout on, every booking is made `:intermediated`, even
   when the host's Stripe account cannot take charges. The checkout then
   refuses with `payments.host_not_connected` and the booking expires as
   `payment_failed`: that host is never paid. A booking whose host's
   account takes no charges must be paid directly (`payment_mode:
   :direct`), and a booking whose host lost the account must not offer the
   checkout among its verbs.
2. The periodic reconciliation of bookings cancels accepted bookings whose
   payment is still in flight (a pending boleto or Pix, a checkout opened
   near the deadline), although the unpaid-booking deadline leaves them
   alone. The payment then lands on a cancelled booking and is refunded.
   The reconciliation must agree with the deadline: it lapses an accepted
   booking with no charge in flight, and leaves one with a live charge.
3. When a traveler opens a second checkout and then pays the first one,
   which was dropped, the money stays captured. A dropped checkout that is
   paid must be refunded, and the newer checkout stays live.
