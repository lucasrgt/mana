Bugs in the hosts app's agenda (the operations board):

1. The "Passado" (past) chip is offered, but choosing it does nothing: the
   view model refuses that filter. It must show what already happened.
2. A day chip such as "Sex 23" shows every Friday, not that date. A chip
   shows its own date only; a booking past the six days after today falls
   under no day chip (it shows under "all").
3. The property filter resets when the host comes back from another screen.
   A link with no property must keep the property the host chose: give the
   view model `bool keepsFor(String? property)` and let the route's `keep`
   use it.
4. With more than 32 bookings the agenda's order shuffles: the comparator
   answers 0 for different bookings and Dart's sort is not stable. Keep the
   agenda's order, proposals first.
5. An action that went through (accept, cancel, a counter proposal, a
   review, a reply) is shown as failed when reading the lists again after it
   fails. A change that went through is never told as failed.
