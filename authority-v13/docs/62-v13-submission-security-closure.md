# 62. Submission Security and External Intake Closure

## Final trust boundary

Browsers never call Submission API. Public Web and Response Portal are same-origin SvelteKit BFFs. Every BFF-to-Submission request carries a single-use request-bound Gurine Service Assertion. Scoped operations additionally carry an opaque `X-Gurine-Submission-Session` token; raw session tokens exist only inside authenticated-encrypted host-only BFF cookies.

## One-time links

Response, receipt, subscription verification and management tokens are accepted only by BFF exchange routes. The BFF sends the token in an internal POST body, receives a scoped session, sets a sealed cookie, and returns `303` to a token-free canonical route. Query strings are `no-store`, `no-referrer` and redacted from access logs and traces.

## Correction request state machine

`create draft → save → upload → finalize/scan → preview → atomic submit → receipt`. Final submission locks the exact draft version, rejects non-clean attachments, creates the immutable request and attachment rows in one transaction, consumes the draft session and issues a read-only receipt session.

## Anonymous starts

Contact, correction-draft creation, dataset export and subscription creation require BFF service assertion, same-origin CSRF, rate limiting, abuse proof and idempotency. They do not require a fictional pre-existing user token.
