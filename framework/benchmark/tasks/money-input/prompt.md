Four price fields in the apps (a combo's price and a promotion in the hosts
app, a service option's price, an ad's price in the OS) parse points and
commas four ways. The combo price rewrites its own text on every key (1
becomes 1,00, and a digit can never be deleted, so the price reads zero),
the number keyboard offers only a point (an iPhone's, nothing), and a point
is dropped as a thousands mark, so 12.50 reads 1250.

Make every price field type reais from the cents, one way in every app:

- The design system gets `AppInputKind.money`: digits only, filled from the
  cents (typing 1 shows 0,01; 1234 shows 12,34), the last digit off at each
  delete (deleting the comma takes the last digit off too), and a point
  typed on an English keyboard is not a decimal mark.
- It also exports `int? moneyCents(String text)` (null when there is no
  digit; a text with a comma or a point is in cents, so `'1.234,56'` is
  123456; one without, saved before the field filled the cents, is whole
  reais, so `'80'` is 8000) and `String moneyText(int cents)`
  (`'1.234,56'`).
- The hosts app's `PropertyField` takes `money: true` for a price, and every
  price field above uses the money kind.
