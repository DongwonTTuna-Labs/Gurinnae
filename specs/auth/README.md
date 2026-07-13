# Gurine Internal Assertion Protocol v1

Status: **FINAL**  
Specification version: **13.0.0**

The Review Console BFF authenticates browser requests and calls the private Identity API with a request-bound service assertion. The Identity API resolves the opaque session, consumes any required step-up authorization, and returns a request-bound actor assertion. The Control API accepts only the actor assertion and never receives browser cookies or CSRF tokens.

Authority files:

- `assertion-contract.yaml`
- `service-assertion.schema.json`
- `actor-assertion.schema.json`
- `test-vectors/*.json`

Both assertion types are HMAC-SHA-256, compact, request-bound, short-lived and single-use. The positive vectors contain test-only keys and deterministic tokens; production keys are supplied only through the secret manager.
