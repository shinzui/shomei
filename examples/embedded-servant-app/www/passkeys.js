// @github/webauthn-json from a CDN: create()/get() wrap navigator.credentials and do the
// base64url <-> binary conversion, returning plain JSON ready to POST. No bundler needed.
import { create, get, supported }
  from "https://unpkg.com/@github/webauthn-json@2.1.1/dist/esm/webauthn-json.js";

const logEl = document.getElementById("log");
const log = (m) => { logEl.textContent += m + "\n"; };

// The bearer access token from a completed login, held in memory for the enroll step.
let accessToken = null;

async function postJSON(path, body, auth) {
  const headers = { "Content-Type": "application/json" };
  if (auth) headers["Authorization"] = "Bearer " + auth;
  const res = await fetch(path, { method: "POST", headers, body: JSON.stringify(body) });
  return { ok: res.ok, status: res.status, json: res.ok ? await res.json() : await res.text() };
}

// --- Step 1 + 3: log in with password; if MFA is required, run the assertion (step-up). ---
document.getElementById("loginBtn").addEventListener("click", async () => {
  if (!supported()) { alert("WebAuthn is not supported on this device"); return; }
  const email = document.getElementById("email").value;
  const password = document.getElementById("password").value;

  const r = await postJSON("/auth/login", { email, password });
  if (!r.ok) { log("login failed: " + r.json); return; }

  if (r.json.status === "complete") {
    accessToken = r.json.token.accessToken;
    log("logged in (no passkey on this account). Enroll one below.");
  } else if (r.json.status === "mfa_required") {
    log("password ok — passkey required, running assertion…");
    // r.json.options is the WebAuthn get() options the server chose.
    const assertion = await get({ publicKey: r.json.options.publicKey });
    const c = await postJSON("/auth/mfa/complete",
      { ceremonyId: r.json.ceremonyId, assertion });
    if (!c.ok) { log("mfa complete failed: " + c.json); return; }
    // /auth/mfa/complete returns a token pair directly.
    accessToken = c.json.accessToken;
    log("MFA complete — tokens issued.");
  }
  document.getElementById("enrollBtn").disabled = (accessToken === null);
});

// --- Step 2: enroll a passkey (authenticated with the bearer token). ---
document.getElementById("enrollBtn").addEventListener("click", async () => {
  if (!supported()) { alert("WebAuthn is not supported on this device"); return; }
  if (!accessToken) { log("log in first"); return; }
  const label = document.getElementById("label").value;

  const b = await postJSON("/auth/passkeys/register/begin", {}, accessToken);
  if (!b.ok) { log("register/begin failed: " + b.json); return; }

  // b.json.options is the WebAuthn create() options the server chose.
  const credential = await create({ publicKey: b.json.options.publicKey });

  const c = await postJSON("/auth/passkeys/register/complete",
    { ceremonyId: b.json.ceremonyId, credential, label }, accessToken);
  if (!c.ok) { log("register/complete failed: " + c.json); return; }
  log("passkey enrolled: " + c.json.passkeyId + " (" + (c.json.label ?? "no label") + ")");
});
