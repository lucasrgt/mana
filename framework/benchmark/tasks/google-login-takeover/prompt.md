Two account security holes.

1. Anyone can register someone else's email with a password of their own
   (password log-in does not require a verified email). When the email's
   owner later signs in with Google, the account becomes verified, and the
   squatter keeps signing in with their password and their open sessions.
   When Google log-in verifies an account whose email was not verified, the
   password it had and every session it had must stop working. Google log-in
   on an already verified account keeps its password and sessions.
2. After registration is complete, a signed-in person can still change their
   verified phone through the registration steps (`POST /phone-code`, then
   `POST /verify-phone`), which skip the password that a phone change asks
   for. With a stolen session, an attacker takes over the SMS codes. Once
   registration is complete, those two steps must refuse with the error code
   `account.registration_complete` (status 422), and the phone and the
   profiles keep the old number.
