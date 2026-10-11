# Oreo Provider Client Contracts: OpenAI Codex and GitHub Copilot

Slice 3 research output for [PLAN.md](../PLAN.md) ("Verify provider contracts"). Documentation only. This file records no client IDs, client secrets, tokens, or credentials, and it contains no live provider calls. Pi source code is not used as a contract source.

> **Reference material only (fourth round, F2).** The Codex and GitHub Copilot auth contracts in this file are not an Oreo task. Oreo does no login, OAuth flow, token handling, or client registration; pi does. Sections 1.2 and 2.2 record facts only.

- Read date for every source below: **2026-10-10** (system date of this research pass).
- Status values: `documented`, `undocumented`, `needs developer registration`. A `documented` row always cites a source ID from the source log.

> **Scope (2026-10-10, second round, items 1 and 5).** Codex and GitHub Copilot are the first providers to test. Oreo's provider list is no longer limited to them: providers come from pi's ecosystem, and login and model calls go through pi. The contracts below remain the reference for these two. See [architecture](../architecture.md#decisions-2026-10-10-second-round).

> **Reference only (third round, A6).** Oreo is a pi plugin, so auth is not Oreo's job: pi holds the logins, and Oreo performs no login. The Codex and Copilot auth contract details (sections 1.2 and 2.2, Items 1–6) are reference only, not an Oreo implementation requirement. Their facts are kept. Items 7–8 (models, limits, terms) remain reference for the bridge and the smoke test. See [architecture](../architecture.md#decisions-2026-10-10-third-round).

## Summary

- **Codex.** The only documented route for a third-party app to use a ChatGPT plan is OpenAI's open-source "Sign in with ChatGPT" flow (SIWC, sources C1–C2). It uses dynamic client registration (no developer-owned client ID, no secret), PKCE, and a `127.0.0.1` loopback callback. Inference then goes directly to `https://api.openai.com/v1/responses`. Eligibility for Oreo is not confirmed. No documented device-code route exists for third-party clients.
- **Copilot.** GitHub documents OAuth device flow with an OAuth App (device flow enabled, no secret). The only documented consumer of the resulting token is the Copilot SDK. The SDK runs the Copilot CLI as a child process and uses that CLI's agent loop. No documented HTTP inference API exists. Direct calls to Copilot hosts would be undocumented.
- **Conflicts with architecture.** Two items in [architecture.md](../architecture.md) do not match the documents: the Copilot "token exchange" step, and the assumption that Oreo calls providers directly with its own loop. See [Architecture gaps](#architecture-gaps).

## Status legend

| Status | Meaning |
|---|---|
| `documented` | Stated in an official source listed below. Source ID cited on the row. |
| `undocumented` | Not in official documentation. It may appear in provider source code or a network allowlist. Do not depend on it without developer approval. |
| `needs developer registration` | Requires an Oreo-specific registration, eligibility confirmation, or a developer decision before use. |

## Source log

Source type: `fetch` = page read in full by the fetch tool; `fetch+find` = fetched and searched for specific passages; `excerpt` = read only from search-result excerpts, not the full page.

### OpenAI Codex sources

| ID | Title | URL | Read | Type |
|---|---|---|---|---|
| C1 | Sign in with ChatGPT: open-source overview | https://developers.openai.com/siwc/token-sharing-open-source | 2026-10-10 | fetch |
| C2 | Registration and sign-in (SIWC open-source) | https://developers.openai.com/siwc/token-sharing-open-source/sign-in | 2026-10-10 | fetch |
| C3 | Accounts and sessions (refresh, revocation, multiple accounts) | https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions | 2026-10-10 | fetch |
| C4 | Token reference (lifetimes, access-token claims) | https://developers.openai.com/siwc/token-sharing-open-source/token-reference | 2026-10-10 | fetch |
| C5 | Models and inference | https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference | 2026-10-10 | fetch |
| C6 | Codex app-server: sign in with ChatGPT | https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server | 2026-10-10 | fetch |
| C7 | Preview limitations (Responses API restrictions) | https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations | 2026-10-10 | fetch |
| C8 | Errors and recovery | https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery | 2026-10-10 | fetch |
| C9 | Self-hosted VMs | https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms | 2026-10-10 | fetch |
| C10 | Sign in with ChatGPT quickstart | https://developers.openai.com/siwc/quickstart | 2026-10-10 | fetch |
| C11 | Request a client ID (commercial partner waitlist) | https://developers.openai.com/siwc/request-client-id | 2026-10-10 | fetch (short page) |
| C12 | OpenID Connect discovery document for auth.openai.com | https://auth.openai.com/.well-known/openid-configuration | 2026-10-10 | fetch (raw JSON) |
| C13 | Codex authentication | https://developers.openai.com/codex/auth | 2026-10-10 | fetch |
| C14 | Codex App Server (ChatGPT Learn) | https://developers.openai.com/codex/app-server | 2026-10-10 | fetch+find |
| C15 | Codex models | https://developers.openai.com/codex/models | 2026-10-10 | fetch |
| C16 | OpenAI API: Create a model response (Responses) | https://developers.openai.com/api/reference/resources/responses/methods/create | 2026-10-10 | fetch+find |
| C17 | Codex CLI command reference (`codex login --device-auth`) | https://developers.openai.com/codex/cli/reference | 2026-10-10 | excerpt |
| C18 | OpenAI open-source Codex, device-code module (pinned commit `5af85998`) | https://github.com/openai/codex/blob/5af85998/codex-rs/login/src/device_code_auth.rs | 2026-10-10 | fetch (raw); open-source code, not documentation |
| C19 | OpenAI Terms of Use (rest of world) | https://openai.com/policies/row-terms-of-use/ | 2026-10-10 | excerpt only; direct fetch returned HTTP 403 |
| C20 | Using Codex with your ChatGPT plan (Help Center) | https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan | 2026-10-10 | excerpt |

### GitHub Copilot sources

| ID | Title | URL | Read | Type |
|---|---|---|---|---|
| G1 | GitHub OAuth setup for the Copilot SDK | https://docs.github.com/en/copilot/how-tos/copilot-sdk/setup/github-oauth | 2026-10-10 | fetch |
| G2 | Copilot SDK authentication | https://docs.github.com/en/copilot/how-tos/copilot-sdk/auth/authenticate | 2026-10-10 | fetch |
| G3 | Copilot SDK: bundled CLI (repo doc) | https://github.com/github/copilot-sdk/blob/main/docs/setup/bundled-cli.md | 2026-10-10 | fetch |
| G4 | Copilot SDK and CLI compatibility | https://docs.github.com/en/copilot/how-tos/copilot-sdk/troubleshooting/compatibility | 2026-10-10 | fetch+find |
| G5 | Copilot SDK streaming session events | https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/streaming-events | 2026-10-10 | fetch+find |
| G6 | Copilot SDK in public preview (GitHub changelog) | https://github.blog/changelog/2026-04-02-copilot-sdk-in-public-preview/ | 2026-10-10 | fetch |
| G7 | Copilot SDK Node.js README (`reasoningEffort`, `listModels`) | https://github.com/github/copilot-sdk/blob/c638a5e3/nodejs/README.md | 2026-10-10 | excerpt |
| G8 | Supported AI models in GitHub Copilot | https://docs.github.com/en/copilot/reference/ai-models/supported-models | 2026-10-10 | fetch+find |
| G9 | Authorizing OAuth apps (web flow, device flow, refresh) | https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps | 2026-10-10 | fetch+find |
| G10 | Creating an OAuth app | https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app | 2026-10-10 | fetch+find |
| G11 | Scopes for OAuth apps | https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps | 2026-10-10 | fetch+find |
| G12 | Copilot network allowlist reference | https://docs.github.com/en/copilot/reference/allowlist-reference | 2026-10-10 | fetch+find |
| G13 | Usage limits for GitHub Copilot | https://docs.github.com/en/copilot/concepts/billing-and-usage/individuals/usage-limits | 2026-10-10 | fetch |
| G14 | Usage-based billing for individuals | https://docs.github.com/en/copilot/concepts/billing/usage-based-billing-for-individuals | 2026-10-10 | fetch |
| G15 | GitHub Terms of Service (sections H, J, K) | https://docs.github.com/en/site-policy/github-terms/github-terms-of-service | 2026-10-10 | fetch+find |
| G16 | GitHub Acceptable Use Policies | https://docs.github.com/en/site-policy/acceptable-use-policies/github-acceptable-use-policies | 2026-10-10 | fetch+find |
| G17 | GitHub Copilot Product Specific Terms (deprecated 2026-03-05) | https://github.com/customer-terms/github-copilot-product-specific-terms | 2026-10-10 | fetch |
| G18 | GitHub Models retirement notice | https://docs.github.com/en/rest/models/inference | 2026-10-10 | fetch |
| G19 | What changed with Copilot billing (legacy) | https://docs.github.com/en/copilot/reference/copilot-billing/request-based-billing-legacy/what-changed-with-billing | 2026-10-10 | excerpt |
| G20 | Copilot SDK server-to-server tokens | https://docs.github.com/en/copilot/how-tos/copilot-sdk/auth/server-to-server-tokens | 2026-10-10 | excerpt |

---

## 1. OpenAI Codex

> Reference only (third round, A6). Not an Oreo implementation requirement.

### 1.1 Route summary

Documented third-party route (SIWC open-source): the user signs in at `auth.openai.com`, consents to plan usage, and Oreo sends Responses requests to `api.openai.com/v1` with that user's OAuth access token (C1, C2, C5). The Codex app-server (C6) is also documented, but it runs Codex as a separate child process. Oreo's architecture rules that out, so it is not the planned route.

### 1.2 Contract items

**Item 1. Authentication flow**

| Topic | Finding | Status | Source |
|---|---|---|---|
| Flow type | OAuth 2.0 authorization code with PKCE inside OpenID Connect. Official step text: "Your application starts an OpenID Connect sign-in with PKCE." Then: "The person authenticates and consents with OpenAI." | documented | C10, C2 |
| Client authentication | Public client. "No client secret is required." | documented | C2 |
| Device code for third-party clients | Not in the SIWC docs. The discovery document has no `device_authorization_endpoint` (C12). Device-code login exists only in Codex's own clients: app-server `chatgptDeviceCode` (C14) and `codex login --device-auth` (C17). OpenAI's open-source Codex calls `{issuer}/api/accounts/deviceauth/usercode` and `/deviceauth/token` with Codex's own client identifier (C18). | undocumented | C12, C14, C17, C18 |
| Headless alternative | Documented: complete the OAuth flow locally in a browser, then transfer the credential record over a secure channel such as SSH to the VM. The VM keeps its own `ext_agent_host_id`. | documented | C9 |
| Codex access tokens | Enterprise-admin feature for trusted non-interactive automation. Not for personal or work accounts used by Oreo. | documented (not applicable) | C13 |

**Item 2. Client registration**

| Topic | Finding | Status | Source |
|---|---|---|---|
| Who registers | The end user. First sign-in sends `client_id=dynamic_agent_client`, `agent_name_hint`, and `ext_agent_host_id`. The callback returns the issued `client_id`, which Oreo saves per ChatGPT account. "This direct flow needs neither a client secret nor a partner API key." | documented | C2 |
| Developer-owned client | Not needed on the open-source path. Oreo still has to confirm eligibility (next row). | documented | C2 |
| Eligibility | "ChatGPT plan usage is available to all open-source partners and selected private clients." Commercial partners: "currently offered to a select group" with a waitlist (C11). Hosted or paid apps: complete the interest form (C1). Whether Oreo, a private repo today, qualifies as "open-source" is not stated. | needs developer registration | C1, C10, C11 |
| Eligible plans | "Eligible ChatGPT Plus and Pro users can use their ChatGPT plan." Business, Enterprise, and Edu are not named. | documented | C10 |
| Required request fields | `client_id`, `agent_name_hint` (new registration only), `ext_agent_host_id`, `response_type=code`, `redirect_uri`, `scope`, `resource`, `state`, `nonce`, `code_challenge`, `code_challenge_method=S256`. | documented | C2 |
| `agent_name_hint` | Display metadata; the user can edit it before approval. Must be the same app name across installs. | documented (value needs developer choice) | C2 |
| Host ID | Opaque, persisted before first sign-in. Preferred form: `urn:ietf:params:oauth:jwk-thumbprint:…` (RFC 9278). `urn:uuid:` and `did:key:` are also accepted. Not an authentication credential. | documented | C1 |
| Re-registration | Each account keeps its own registration. "Never combine one registration's client ID with another registration's tokens." | documented | C3 |

**Item 3. Redirect and callback**

| Topic | Finding | Status | Source |
|---|---|---|---|
| URI form | `http://127.0.0.1:<port>/auth/callback`. Use `127.0.0.1`, not `localhost`. The scheme, host, and path are fixed. Only the port may change between attempts. | documented | C2 |
| Exact match | The same URI, including the port, must appear in the authorization request and the code exchange. | documented | C2 |
| Listener timing | Start the listener before opening the browser. Generate fresh `state`, `nonce`, and PKCE values for each attempt. | documented | C2 |
| Port | Example port `1455`. No fixed port is mandated. The architecture says the user "has approved a loopback redirect URI", but the approved value is not recorded in this repo. | needs developer registration | C2, architecture.md |
| Callback parameters | `code`, `state`, `scope`, and `client_id` (new registration only). Reject a different `client_id` on re-authorization. On `error=access_denied`, validate state and stop without exchanging a code. | documented | C2 |

**Item 4. Scopes**

| Scope | What it grants (per the source) | Status | Source |
|---|---|---|---|
| `openid profile email` | Identity: ID token, name, email, picture. "Identity scopes don't grant access to ChatGPT conversations or OpenAI API resources." | documented | C10, C2 |
| `offline_access` | Returns a `refresh_token`. Refresh is rotating (see Item 6). | documented | C2, C4 |
| `resource.invoke` | Required, with the next scope, for plan usage. The docs say it is a "Responses API scope" but do not define its finer semantics. | documented (requirement); semantics undocumented | C2, C10 |
| `chatgpt.tokens.use.direct` | Permission to use the user's ChatGPT plan for eligible Responses requests. A valid ID token alone does not authorize plan usage. Check the granted scopes before inference. | documented | C2, C8 |
| `resource` parameter | `https://api.openai.com/v1`. Sent on authorization and token requests. | documented | C2 |
| Re-consent | `prompt=consent` is supported now. `force_reconsent=true` only after OpenAI confirms deployment. Do not force consent on every sign-in. | documented | C8 |

**Item 5. Endpoints**

| Endpoint | URL | Status | Source |
|---|---|---|---|
| Authorization | `https://auth.openai.com/api/accounts/authorize` | documented | C2, C12 |
| Token (code exchange and refresh) | `https://auth.openai.com/api/accounts/oauth/token` | documented | C2, C3, C12 |
| Revocation | `https://auth.openai.com/api/accounts/oauth/revoke` (take it from discovery) | documented | C3, C12 |
| Discovery | `https://auth.openai.com/.well-known/openid-configuration` | documented | C3, C12 |
| JWKS (ID-token signature check) | `https://auth.openai.com/.well-known/jwks.json` | documented | C12, C2 |
| Device authorization | No endpoint in discovery. Codex-internal paths only (see Item 1). | undocumented | C12, C18 |
| API base URL | `https://api.openai.com/v1`. `POST /responses` for inference; `GET /models` for the account catalog. | documented | C5, C2 |
| ChatGPT backend | Do not point the SIWC flow at `chatgpt.com/backend-api`. "Use the public Responses API endpoint." | documented (prohibition) | C5 |

**Item 6. Token lifetime, refresh, and revocation**

| Topic | Finding | Status | Source |
|---|---|---|---|
| Access token | 1 hour (`expires_in: 3600`). | documented | C4 |
| Refresh token | 30 days. Each successful refresh returns a replacement with a fresh 30-day lifetime. "Successive replacements have no fixed limit while each token remains valid." | documented | C4 |
| Refresh request | Form-encoded `POST` to the token endpoint: `grant_type=refresh_token`, the saved issued `client_id` (not `dynamic_agent_client`), the saved `refresh_token`, `resource=https://api.openai.com/v1`. Omit `scope`. Serialize refreshes per session. | documented | C3 |
| Refresh errors | `invalid_grant`, `invalid_refresh_token`, `token_expired`, `refresh_token_expired`, `refresh_token_invalidated`, `refresh_token_reused`: clear the tokens and repeat OAuth with the saved client ID. `invalid_client`: configuration error. | documented | C8 |
| Revocation | Form-encoded `POST` with `token`, `token_type_hint=refresh_token`, and `client_id`. An empty `200` means success. Retry on network error or `5xx` while the refresh token exists. Revocation does not delete the registered client. | documented | C3 |
| Disconnection | OpenAI does not notify the app. The user can disconnect in ChatGPT Settings. Detect it on a request or refresh. | documented | C8 |
| Local storage | Owner-only file (`0600`). Access, refresh, and ID tokens never go in URLs, logs, or source control. | documented | C2, C3 |

**Item 7. Model and API capabilities**

| Topic | Finding | Status | Source |
|---|---|---|---|
| Model catalog | `GET https://api.openai.com/v1/models` with the bearer token. Show entries with `visibility == "list"` (`slug`, `display_name`). Refresh the list on account switch. The docs say the response contains a `models` array; verify the shape at runtime. | documented | C5 |
| Known model IDs | Responses enum includes `gpt-6-astra`, `gpt-6.1-sol`, `gpt-6-sol`, `gpt-6-luna`, `gpt-5.6-*`, `gpt-5.5`. Availability varies by account, rollout, and client. | documented (account-specific) | C16, C15 |
| Retirements | `gpt-5.5` retires from Codex with ChatGPT sign-in on **2026-10-14**. `gpt-5.4` and `gpt-5.4-mini` retired 2026-08-31. `gpt-5.2` and `gpt-5.3-codex` are deprecated for ChatGPT sign-in. | documented | C15 |
| Streaming | Required on this route: `store: false` and `stream: true`. Treat success only as `response.completed`. Handle `response.failed`, `response.incomplete`, and interrupted streams separately. | documented | C5, C7 |
| Tool calls | Function and custom tools are supported, grouped in namespaces or passed as `additional_tools` items. Not supported: image generation, file search, Code Interpreter, native computer use, hosted MCP and connectors, Responses `tool_search`, and `programmatic_tool_calling` in top-level `tools`. Hosted web search is subject to account policy. | documented | C7 |
| Thinking levels | Responses `reasoning.effort` enum: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` (C16). Codex maps Astra "Light" to `low` in configuration (C15). The SIWC route does not list `reasoning` among unsupported fields, but the docs never state it is accepted. | undocumented for this route; verify before relying on it | C16, C15, C7 |
| Fields rejected on this route | `background`, `conversation`, `max_output_tokens`, `max_tool_calls`, `metadata`, `moderation`, `multi_agent`, `prompt`, `prompt_cache_retention`, `safety_identifier`, `temperature`, `top_logprobs`, `top_p`, `truncation`, `user`. Also `previous_response_id` over HTTP, and explicit `system` message items (use `instructions`). | documented | C7 |
| Conversation state | No server-side memory (`store: false`). Oreo must resend the full history in `input` every turn. This fits Oreo's SQLite store. | documented | C7, C5 |
| Inputs | Text, images, and files when the model accepts them. Audio and video input, the Files API, and transcription are not supported on this route. | documented | C7 |
| Codex app-server models | `model/list` returns `supportedReasoningEfforts`, `inputModalities`, `defaultReasoningEffort`. Relevant only if the app-server route were used. | documented (app-server only) | C14 |

**Item 8. Limits and terms**

| Topic | Finding | Status | Source |
|---|---|---|---|
| Usage limits | Plus: a five-hour limit, shared across every app using the plan, including private and open-source clients. Pro: no five-hour limit. Exceeding a limit returns HTTP `429` with `subscription_sharing_usage_limit_exceeded`. Numeric allowances are not published in the SIWC docs; the Codex plan allowances are on the Help Center page (C20, excerpt). | documented (numbers not published) | C1, C8, C20 |
| Usage visibility | ChatGPT Settings → Usage shows app usage and access. | documented | C1 |
| Third-party restrictions | The SIWC open-source route explicitly allows open-source clients and selected private clients. Hosted or paid apps need the interest form. | documented | C1, C10 |
| Terms | OpenAI Terms of Use prohibit reverse engineering or decompiling the Services, and "automatically or programmatically extract data or Output". Read from a search excerpt only; the page returned HTTP 403. Oreo must not reverse-engineer ChatGPT or Codex internals. Use the SIWC route only. | documented (excerpt); no legal check (fourth round, F1) | C19 |
| Codex open-source license | Not checked. | not verified | — |

---

## 2. GitHub Copilot

> Reference only (third round, A6). Not an Oreo implementation requirement.

### 2.1 Route summary

Documented route: a GitHub OAuth App (or GitHub App) with device flow enabled gives Oreo a user access token (`gho_`, `ghu_`, or `github_pat_`). The documented consumer of that token is the Copilot SDK. The SDK starts the Copilot CLI runtime as a child process and talks to it over JSON-RPC (G1, G2, G3, G4). The SDK's runtime owns the agent loop (G6). That differs from Oreo's design, so the SDK path needs a developer decision. Direct HTTP calls to Copilot hosts are not documented.

### 2.2 Contract items

**Item 1. Authentication flow**

| Topic | Finding | Status | Source |
|---|---|---|---|
| Device flow | "The device flow allows you to authorize users for a headless application, such as a CLI tool." Steps: (1) request device and user codes; (2) user enters the user code at `https://github.com/login/device`; (3) app polls for the token. Enable device flow in the app settings first. | documented | G9, G10 |
| Device code request | `POST https://github.com/login/device/code` with `client_id` and optional `scope`. Response: `device_code`, `user_code`, `verification_uri`, `expires_in` (default 900), `interval` (default 5). | documented | G9 |
| Token poll | `POST https://github.com/login/oauth/access_token` with `client_id`, `device_code`, and `grant_type=urn:ietf:params:oauth:grant-type:device_code`. No `client_secret`. | documented | G9 |
| Web application flow | `GET https://github.com/login/oauth/authorize`, then `POST .../access_token` with `code` and `client_secret`. PKCE is supported: `code_challenge` (S256 only). | documented | G9 |
| "Copilot token exchange" | No documented exchange step. The SDK passes the `gho_`/`ghu_`/`github_pat_` token directly (G2). The only mention of `api.github.com/copilot_internal/*` is in the network allowlist, labelled "User Management" (G12). | undocumented | G2, G12 |

**Item 2. Client registration**

| Topic | Finding | Status | Source |
|---|---|---|---|
| Who may register | Any GitHub account, under Developer settings → OAuth Apps → New OAuth App. Organizations use Organization Settings → Developer Settings. | documented | G1 |
| Required fields | Application name; homepage URL; optional description; authorization callback URL (up to 10); "Enable Device Flow" checkbox. | documented | G10 |
| Token expiry default | "Expire user access tokens is enabled by default" for new OAuth Apps. | documented | G10 |
| Public client | Device-flow code and poll requests take no client secret. The refresh request takes no secret only for tokens issued by device flow. | documented | G9 |
| GitHub App alternative | "GitHub Apps offer finer-grained permissions and are recommended for new projects" (G1). Device flow must be enabled in the App settings as well (G9). | documented | G1, G9 |
| Oreo registration | No OAuth App or GitHub App exists for Oreo, and none is planned (fourth round, F2). | not an Oreo task (fourth round, F2) | — |

**Item 3. Redirect and callback**

| Topic | Finding | Status | Source |
|---|---|---|---|
| Device flow | Neither the device-code request nor the token poll sends a `redirect_uri`. | documented | G9 |
| Callback URL field | Required by the registration form. For a device-only App, the docs do not say what value to enter. | needs developer registration | G10 |
| Loopback | For the web flow, a loopback `redirect_uri` may use a different port from the registered URL, for example `http://127.0.0.1:1234/path` against `http://127.0.0.1/path`. The RFC 8252 advice is `127.0.0.1` rather than `localhost`. | documented | G9 |
| Wildcard matching | A per-callback setting. Apps created before 2026-08-03 have it enabled by default. The docs recommend disabling it if it is not needed. | documented | G9 |

**Item 4. Scopes**

| Scope | What it grants (per the source) | Status | Source |
|---|---|---|---|
| (none) | "Grants read-only access to public information". | documented | G11 |
| `offline_access` | Requests an expiring access token plus a refresh token, even if the App is not set to expire tokens. | documented | G11, G9 |
| Copilot-specific scope | None appears in GitHub's OAuth scope reference, and the SDK docs name none. Third-party scope indexes were not used as sources. | undocumented | G11, G1 |
| Scope on refresh | A refresh cannot change scopes. The new token keeps the previous scopes. | documented | G9 |
| Scope needed for Copilot inference | Not documented. The developer must test the minimum set. | undocumented | — |

**Item 5. Endpoints**

| Endpoint | URL | Status | Source |
|---|---|---|---|
| Device code | `https://github.com/login/device/code` | documented | G9 |
| User verification page | `https://github.com/login/device` | documented | G9 |
| Token, poll, and refresh | `https://github.com/login/oauth/access_token` | documented | G9 |
| Web authorization | `https://github.com/login/oauth/authorize` | documented | G9 |
| Identity API | `https://api.github.com`, for example `GET /user` | documented | G9 |
| Copilot inference host | `https://*.githubcopilot.com/*` is listed as an "API service for Copilot suggestions" in the network allowlist. No request, response, or auth contract is published. | undocumented (host listed, API not) | G12 |
| Copilot token exchange | `https://api.github.com/copilot_internal/*` appears in the allowlist only. | undocumented | G12 |
| Copilot SDK runtime | Node.js, .NET, and Python bundle the CLI. Go, Java, and Rust need a CLI installed or configured. The SDK starts the runtime as a child process and communicates over stdio JSON-RPC. | documented | G3, G4 |

**Item 6. Token lifetime, refresh, and revocation**

| Topic | Finding | Status | Source |
|---|---|---|---|
| Expiring token pair | Access token: 8 hours (`expires_in: 28800`). Refresh token: expires after 6 months without use (`refresh_token_expires_in: 15897600`). Refresh returns a new pair; the old pair stops working. | documented | G9, G10 |
| Refresh request | `POST https://github.com/login/oauth/access_token` with `grant_type=refresh_token`, `client_id`, `refresh_token`. `client_secret` is required "unless the token was generated using the device flow". | documented | G9 |
| Invalid refresh token | `bad_refresh_token`: send the user through device flow again. | documented | G9 |
| Device-flow limits | Device code expires after 15 minutes. Minimum poll interval 5 s. `slow_down` adds 5 s. 50 code submissions per hour per app. 10 tokens per user, App, and scope; creating an eleventh revokes an existing one. | documented | G9 |
| Token prefixes accepted by the SDK | `gho_`, `ghu_`, `github_pat_`. Classic `ghp_` is not accepted. | documented (SDK) | G2 |
| SDK token rotation | With a token provider, the runtime requests a refresh when one hour or less remains. Production tokens "typically last eight hours". Applies only to the SDK. | documented (SDK) | G2 |
| User-side revocation | `https://github.com/settings/connections/applications/:client_id` | documented | G9 |
| App-side revocation API | Not checked in this pass. | undocumented (not verified) | — |

**Item 7. Model and API capabilities**

| Topic | Finding | Status | Source |
|---|---|---|---|
| Model names | Supported-models table lists display names and release status (for example GPT-5.4 GA, GPT-5.5 GA, GPT-5.6 Luna GA). Availability depends on plan and client. | documented | G8 |
| Model IDs | SDK examples use `gpt-5.4`, `claude-sonnet-4.5`, and `auto`. Use `listModels()` for the account's catalog, which returns IDs and capabilities. | documented (SDK) | G1, G2, G4, G7 |
| Retirements | Claude Opus 4.6 and Claude Sonnet 4.5 retire 2026-09-01. Claude Opus 4.7 retires 2026-10-02. | documented | G8 |
| Streaming | Events: `assistant.message_delta` (ephemeral text chunk), `assistant.reasoning_delta`, `assistant.message`, `session.idle` (turn complete). Ephemeral events are not persisted. | documented (SDK only) | G5 |
| Tool calls | Custom tools are registered with the SDK. `assistant.message` carries `toolRequests`. The runtime runs the tool-use loop. The raw wire format is not documented. | documented (SDK only) | G4, G5, G6 |
| Thinking levels | `reasoningEffort`: `low`, `medium`, `high`, `xhigh`. Available only for models whose `capabilities.supports.reasoningEffort` is true. | documented (SDK) | G7, G4 |
| Vision | `capabilities.supports.vision` from `listModels()`. | documented (SDK) | G7 |
| Agent loop | "The same production-tested agent runtime that powers GitHub Copilot cloud agent and Copilot CLI." Oreo's own loop is not used when the SDK runs the session. | documented | G6 |
| Raw HTTP inference contract | Not documented anywhere reviewed. | undocumented | G12, G1 |

**Item 8. Limits and terms**

| Topic | Finding | Status | Source |
|---|---|---|---|
| Subscription | Each user needs an active Copilot subscription for SDK-based use. BYOK is the documented alternative (G2). | documented | G1, G2 |
| Rate limits | Per-user limits. Numeric values are not published. GitHub cites capacity, high usage, fairness, and abuse. | documented (numbers not published) | G13, G1 |
| Billing | Usage-based billing with AI credits (1 credit = $0.01). Copilot CLI and third-party coding agents consume credits. Pro: 1,500 credits per month; Pro+: 7,000; Max: 20,000. The switch from request-based billing took effect 2026-06-01. | documented | G14, G19 |
| Individual terms | Individual users are governed by GitHub Terms of Service Section J (AI features). | documented | G15, G17 |
| API terms | Section H covers API use "including use of the API through a third party product that accesses GitHub". "You may not share API tokens to exceed GitHub's rate limitations." Abuse or excessive requests can suspend API access. | documented | G15 |
| Acceptable use | Prohibits "excessive automated bulk activity" and using servers "to place undue burden on our servers through automated means". | documented | G16 |
| Preview status | The Copilot SDK is in public preview and "available to all Copilot and non-Copilot subscribers" (G6). ToS Section K: "Beta Previews may not be supported or may change at any time." | documented | G6, G15 |
| Third-party direct calls | No permission or prohibition for a third-party client calling Copilot hosts directly was found. The SDK docs describe OAuth-App tokens "on behalf of users" as a supported pattern (G2). | undocumented for direct calls | G2, G15 |
| BYOK | No Copilot subscription needed. Use your own keys with OpenAI, Microsoft Foundry, or Anthropic. This bypasses Copilot authentication. | documented | G2 |
| GitHub Models | Retired 2026-07-30. The playground, catalog, inference API, and BYOK are no longer available. Not an option. | documented | G18 |
| Copilot Product Specific Terms | Deprecated 2026-03-05. They apply only to Business and Enterprise purchased directly from GitHub. Not the individual-user terms. | documented | G17 |

---

## Architecture gaps

These statements in [architecture.md](../architecture.md) and [PLAN.md](../PLAN.md) do not match the documented contracts.

Status after the [2026-10-10 decisions](#decisions-2026-10-10): gaps 4 and 5 were resolved by the direct Copilot route. That route is now superseded, because provider calls go through pi, so gaps 4 and 5 are open again until pi's route is checked. Gap 3 is to be verified by the smoke test through pi. Gaps 1, 2, and 3 are auth details: reference only (third round, A6), and no longer Oreo requirements. Gaps 4–7 remain open for the bridge spike and the smoke test. Codex is tabled for implementation.

1. **Codex headless path.** The architecture calls Codex device-code login "the headless path". No device-code route is documented for third-party clients (Codex Item 1). The documented headless alternative is credential transfer from a browser-capable machine (C9).
2. **Codex loopback URI.** The architecture says the user "has approved a loopback redirect URI". The approved value is not recorded in the repo. The documented rule is `http://127.0.0.1:<port>/auth/callback`, with the port free to vary (C2).
3. **Copilot token exchange.** The architecture lists a "Copilot token exchange" after device flow. No exchange is documented. The SDK uses the GitHub token directly (G2).
4. **Copilot loop ownership and CLI process.** architecture.md says Oreo "independently implements its auth, agent loop, and tools", and PLAN.md slice 6 says adoption "does not require an external agent CLI process per session". The documented Copilot route runs the Copilot CLI runtime and its agent loop (G3, G6). This directly conflicts with the plan unless Oreo accepts it as a deliberate exception.
5. **Direct provider calls.** The architecture says "Oreo calls provider-owned endpoints directly". This holds for Codex (C5). For Copilot, no direct inference endpoint is documented (Copilot Items 5 and 7).
6. **Codex request builder.** Pi-compatible sampling controls (`temperature`, `top_p`, `max_output_tokens`) and server-side history (`previous_response_id`) are rejected on the SIWC route (C7). Slice 2's loop and slice 4's request builder must cope with this: resend history, and do not send those fields.
7. **Model defaults.** `gpt-5.5` retires from Codex with ChatGPT sign-in on 2026-10-14 (C15). Model defaults in `~/.oreo/config.json` must not hard-code it.

## Not verified

- No live calls, accounts, or credentials were used. Every behaviour above comes from documents, not from a running request.
- Whether Oreo qualifies as an open-source client for SIWC (no license or public repo exists yet).
- Whether Business, Enterprise, or Edu ChatGPT accounts can use SIWC plan usage. Only Plus and Pro are named as eligible.
- Whether the SIWC route accepts `reasoning.effort` (Codex Item 7), and the exact shape of `GET /v1/models` (C5 says `models`).
- Whether `resource.invoke` carries any meaning beyond "Responses API access".
- Whether Copilot inference works with no OAuth scope, or which minimal scope set it needs.
- Whether a GitHub OAuth App can revoke its own grant through an API.
- Whether a third-party client may call Copilot hosts directly. Not stated either way in the documents read.
- Whether an extension of pi falls under pi's provider registration. Not checked: no legal or provider-terms check (developer decision, 2026-10-10: Oreo is a pi plugin).
- Terms: the OpenAI Terms of Use page returned HTTP 403, so C19 is excerpt-only. The Codex open-source license was not checked. The Copilot CLI bundling license was not checked.
- Pages read only from search excerpts (C17, C19, C20, G7, G19, G20) were not read in full.

## Decisions (2026-10-10)

> Partly superseded by the runtime decision of 2026-10-10 ([architecture](../architecture.md#runtime-decision-2026-10-10)): login and provider calls go through pi, and the GitHub OAuth App is dropped. Each row shows its current status. Earlier answers are kept as the record.

The developer answered the open questions on 2026-10-10. Numbers Q1–Q10 are the decision items, not the retired question numbers. Focus is GitHub Copilot; Codex is tabled.

| Item | Decision | Status |
|---|---|---|
| Q1. Codex | Earlier answer: Codex implementation is tabled. Codex personal import is superseded (Q4). The Codex contract facts above are unchanged. | tabled |
| Q2. Refresh write-back | Earlier answer: option (b), rotated tokens saved to Oreo's own `~/.oreo/auth.json`. Superseded (2026-10-10, item 2): refresh and storage go through pi, so this write-back no longer applies. | superseded (2026-10-10, item 2) |
| Q3. README and PLAN | Originally updated to match the personal import exception. Both files now follow the 2026-10-10 runtime decision instead. | superseded (2026-10-10, items 1 and 4) |
| Q4. Import flag | Earlier answer: `OREO_PERSONAL_IMPORT=codex,copilot`. Superseded (2026-10-10, item 4): no import is needed, because each user logs in through pi. Kept as the record. | superseded (2026-10-10, item 4) |
| Q5. Codex plan | Tabled, with Q1. | tabled |
| Q6. Legal review | Superseded (fourth round, F1): no legal or provider-terms check. Earlier answer: no legal review is required before release. Superseded in part (2026-10-10, item 5): a provider-terms check was open and was to be done before any public release (Q11). Personal use is not affected. | superseded (fourth round, F1) |
| Q7. OAuth App owner | Earlier answer: the "Oreo" OAuth App under the developer's personal GitHub account. Dropped (2026-10-10, item 3): no OAuth App is registered. | dropped (2026-10-10, item 3) |
| Q8. Callback URL | Earlier suggestion: `http://127.0.0.1/callback`. Dropped (2026-10-10, item 3): no callback URL is needed. | dropped (2026-10-10, item 3) |
| Q9. Copilot scopes | Earlier plan: start with no scopes, checked by the smoke test. Superseded (2026-10-10, items 2 and 3): login goes through pi, and the scope choice moves to pi's login. pi requests `read:user` as a reference only (pi source is not a contract source). | superseded (2026-10-10, items 2 and 3) |
| Q10. Copilot route | Earlier answer: direct, calling pi's undocumented Copilot endpoints (the token exchange and the API host). Superseded (2026-10-10, item 2): provider calls go through pi, so Oreo does not call those endpoints itself. The earlier answer is kept as the record. | superseded (2026-10-10, item 2); endpoints remain unverified |
| Q11. Provider terms | No legal or provider-terms check (developer decision, 2026-10-10: Oreo is a pi plugin). Whether an extension of pi falls under pi's provider registration remains not verified. | superseded (fourth round, F1) |
| Third round A6. Codex and GitHub Copilot auth | Oreo is a pi plugin, so auth is not Oreo's job. Codex is irrelevant to Oreo's auth now. The auth contract details in sections 1.2 and 2.2 are reference only, not an Oreo implementation requirement. Facts are kept. | reference only (third round, A6) |
| Fourth round F1. Legal check | No legal or provider-terms check (developer decision, 2026-10-10: Oreo is a pi plugin). Supersedes A5, A7, and the Q11 pre-release gate. | decided (fourth round) |
| Fourth round F2. Auth | Oreo does no auth work: no login, OAuth flow, token handling, or client registration. These are pi's responsibility. A6 stays: the auth contracts are reference only. | decided (fourth round) |

**Route conflict.** The Copilot SDK route assumed by PLAN slice 6 was replaced by the direct route. The 2026-10-10 runtime decision supersedes the direct route as well: provider calls go through pi. PLAN slice 6 now says so.

