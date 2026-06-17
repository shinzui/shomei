# Shōmei passkey demo page

Static enroll + step-up-login page for the `embedded-servant-app` demo. It runs the real
WebAuthn ceremonies in the browser against the demo's own mounted `/auth` routes, using
`@github/webauthn-json` loaded from a CDN (no bundler).

The demo serves this directory at `/` via a `Raw` route (`serveDirectoryWebApp`). Launch the
demo from the `examples/embedded-servant-app` directory (so this `www/` resolves), or set
`SHOMEI_DEMO_WWW` to an absolute path, then open <http://localhost:8080/index.html>.

Full walkthrough (create an account, enroll a passkey, step-up login): see
[`docs/passkeys.md`](../../../docs/passkeys.md) → "Demo walkthrough".

Files:
- `index.html` — the page (login / enroll / step-up sections).
- `passkeys.js` — the ceremony glue (`navigator.credentials` via `webauthn-json`).
- `style.css` — minimal styling.
