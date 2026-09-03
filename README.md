# QuickAuth iOS SDK

[![Platforms](https://img.shields.io/badge/platforms-iOS%2014%2B-blue.svg)]()
[![Swift](https://img.shields.io/badge/swift-5.9-orange.svg)]()
[![License](https://img.shields.io/badge/license-MIT-green.svg)]()

Drop-in **phone OTP authentication** (SMS or WhatsApp) plus **WhatsApp marketing
attribution** for iOS apps. Pure Swift, no third-party dependencies, ships with
both **headless APIs** and **pre-built SwiftUI / UIKit components**.

---

## Install

### Swift Package Manager

```swift
.package(url: "https://github.com/quickauthin/quickauth-sdk-ios", from: "1.2.0")
```

Then add `"QuickAuth"` to your target dependencies.

### CocoaPods

```ruby
pod 'QuickAuthIn', '~> 1.2'
```

> Note: the pod is named `QuickAuthIn` on CocoaPods (the unsuffixed `QuickAuth` name was already taken by an unrelated library). Your Swift code still uses `import QuickAuth` — only the Podfile entry uses the suffixed name.

---

## Authentication model

The SDK never embeds your `client_secret`. Instead — same pattern Twilio Verify
uses for its mobile SDKs — your **backend** mints a short-lived (10 minute)
`sessionToken` by calling QuickAuth server-to-server, and the SDK calls a
closure (`onTokenExpiry`) you provide to fetch one whenever it needs a fresh
token.

```
┌────────────┐  /api/quickauth-token   ┌──────────────────┐  POST /v1/sdk/session
│  Your app  │ ──────────────────────▶ │ Your backend     │ ──────────────────────▶ QuickAuth
│ (this SDK) │ ◀────────────────────── │ (client_secret)  │ ◀────────────────────── (returns sessionToken, exp 10m)
└────────────┘    sessionToken          └──────────────────┘
```

The SDK:
- caches the token in-memory,
- parses `exp` from the JWT,
- calls `onTokenExpiry` again ~30s before expiry (single-flight: concurrent
  callers share one refresh),
- on a `401` response, invalidates the token and retries the request once.

---

## Quick start

### 1. Initialize on app launch

```swift
import QuickAuth

@main
struct MyApp: App {
    init() {
        QuickAuth.shared.initialize(onTokenExpiry: {
            // Call YOUR backend; do NOT call QuickAuth directly from the app.
            let response = try await myAPI.fetch("/api/quickauth-token")
            return response.sessionToken
        })
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

The SDK defaults the API base to `https://api.quickauth.in` and (in DEBUG)
warns you if the Associated Domains entitlement needed for domain-bound SMS
autofill is missing.

### 2. Component mode (zero-config UI)

```swift
import SwiftUI
import QuickAuth

struct LoginView: View {
    @State private var phone = "+919876543210"
    var body: some View {
        QuickAuthLoginButton(
            phone: phone,
            onSuccess: { jwt in /* save jwt */ },
            onError:   { err in print(err) }
        )
    }
}
```

UIKit equivalent: `QuickAuthLoginButtonView`, `QuickAuthOTPTextField`.

### 3. Headless mode (your own UI)

Every outcome — sent, auto-read, verified, rejected, failed — arrives on one
typed event stream. Register the handler once, then drive the state machine:

```swift
QuickAuth.shared.setAuthEventHandler { event in
    switch event {
    case .otpSent(let sessionId, let channel, let expiresIn): showOtpInput()
    case .otpAutoRead(let code):                              prefill(code)
    case .verified(let requestId, _):                         finishLogin(requestId)
    case .otpFailed(let message):                             showError(message)
    case .error(let code, let message):                       showError(message)
    }
}

try await QuickAuth.shared.auth.initiate(phone: "+919876543210", channel: .auto)
try await QuickAuth.shared.auth.submitOtp("123456")
```

Forward `requestId` to your backend, which confirms it with QuickAuth via
`GET /v1/auth/status?requestId=…` (`X-Client-Id` / `X-Client-Secret`) and mints
its own session JWT against its own user table. See
<https://quickauth.in/docs/backend>.

Each `initiate` supersedes the previous attempt, and produces at most one
terminal event (`.verified` / `.otpFailed` / `.error`) for that attempt.

### 4. Resending

```swift
try await QuickAuth.shared.auth.resendOtp()
```

It takes **no phone number** on purpose: it resends to the number the live
attempt is already for, carrying that attempt's channel and `autoSubmit`
setting. Passing the number again is an opportunity to pass a different one by
accident, which starts a second transaction and leaves the user holding two
codes, only one of which works.

Within your expiry window the backend returns the *same* code and pushes the
expiry forward; past it, a fresh one. With no attempt in flight the call throws
`QuickAuthError.invalidState` — a resend button should only exist after a code
has been sent.

### 5. Auto-read and `autoSubmit`

iOS gives an SDK no way to observe an inbound SMS. Autofill is done by the OS,
which offers the code as a keyboard suggestion straight into any field with
`textContentType = .oneTimeCode` — **the SDK is never told**. So the bridge is
explicit: hand the code back.

```swift
// Anything that learns the code — your text field, a push payload — feeds it in:
QuickAuth.shared.auth.publishAutoReadCode(code)
```

The bundled fields (`QuickAuthOtpField`, `QuickAuthOTPTextField`) do this for
you, and only for codes that arrive *all at once* — a code the user typed one
digit at a time is not an auto-read. Set `forwardsAutofillToQuickAuth = false`
to forward it yourself.

Ask `initiate` to verify what it reads:

```swift
try await QuickAuth.shared.auth.initiate(phone: phone, autoSubmit: true)
```

- **Off by default** — submitting on the user's behalf is a surprise unless they
  asked for it.
- **Armed by `initiate` itself.** You do not have to subscribe to anything;
  `.otpAutoRead` and auto-submission work with no subscriber present.
- **One submit per attempt.** The same code can reach the SDK twice (an SMS copy
  and a WhatsApp copy, or a field that fires twice). The second would verify a
  code the server has already consumed — a failure landing *after* a success —
  so a one-shot latch allows exactly one, reset on the next `initiate` or
  `resendOtp`.

A Combine publisher of the same codes is available for callers who prefer it —
strictly optional, and subscribing does not double the events:

```swift
QuickAuth.shared.auth.observeOTP().sink { code in self.code = code }
```

### 6. WhatsApp login

```swift
QuickAuth.shared.auth.startWhatsAppLogin(
    businessNumber: "+919574980048",
    returnURL: URL(string: "https://app.example.com/wa-return")
)
```

Handle the return URL in your app:

```swift
.onOpenURL { url in
    Task { _ = try? await QuickAuth.shared.attribution.captureLaunch(url: url) }
}
```

Or via the facade's WhatsApp surface, which also parses the return URL:

```swift
QuickAuth.shared.whatsapp.open(businessNumber: "+919574980048")
if QuickAuth.shared.whatsapp.isReturnURL(url) { … }
```

### 7. Attribution & conversions

```swift
try await QuickAuth.shared.attribution.captureLaunch(url: launchURL)
try await QuickAuth.shared.attribution.trackConversion(
    event: "signup", value: 0, currency: "INR"
)
```

---

## Backend: minting `sessionToken`

Your backend exposes a thin endpoint that authenticates the logged-in user
(however you do that today) and proxies a call to QuickAuth. Below is a
**Vapor 4** example; the equivalent Express, Rails, FastAPI etc. is trivial
because it's a single POST.

```swift
// Sources/App/routes.swift
import Vapor

struct QASessionResponse: Content { let sessionToken: String; let expiresIn: Int }

func routes(_ app: Application) throws {
    app.post("api", "quickauth-token") { req async throws -> QASessionResponse in
        // 1. Authenticate the request from your app (your existing session / JWT auth).
        let _ = try req.auth.require(User.self)

        // 2. Server-to-server call to QuickAuth.
        let upstream = try await req.client.post("https://api.quickauth.in/v1/sdk/session") {
            try $0.content.encode(["scope": "sdk"])
            $0.headers.add(name: "X-Client-Id",     value: Environment.get("QUICKAUTH_CLIENT_ID")!)
            $0.headers.add(name: "X-Client-Secret", value: Environment.get("QUICKAUTH_CLIENT_SECRET")!)
        }

        struct Upstream: Content { let sessionToken: String; let expiresIn: Int }
        let body = try upstream.content.decode(Upstream.self)
        return QASessionResponse(sessionToken: body.sessionToken, expiresIn: body.expiresIn)
    }
}
```

Node/Express equivalent:

```js
app.post('/api/quickauth-token', requireAuth, async (req, res) => {
  const r = await fetch('https://api.quickauth.in/v1/sdk/session', {
    method: 'POST',
    headers: {
      'Content-Type':  'application/json',
      'X-Client-Id':     process.env.QUICKAUTH_CLIENT_ID,
      'X-Client-Secret': process.env.QUICKAUTH_CLIENT_SECRET,
    },
    body: JSON.stringify({ scope: 'sdk' }),
  });
  res.json(await r.json());
});
```

Never put `client_secret` in your iOS app bundle — anyone can extract it.

### Pre-warming the first request

If you already fetched a token (e.g. during onboarding) you can hand it to the
SDK so the first API call doesn't have to await the network:

```swift
QuickAuth.shared.initialize(config: Config(
    onTokenExpiry: { try await myAPI.fetch("/api/quickauth-token").sessionToken },
    initialToken:  cachedToken
))
```

---

## Trusted-enterprise escape hatch (NOT recommended)

For internal-distribution apps where you _can_ embed `client_secret` (MDM, kiosk,
field-ops apps that don't ship to the public App Store) the SDK can mint its own
token directly:

```swift
QuickAuth.shared.initialize(config: Config(
    unsafeDirectClientId:     "qa_client_xxx",
    unsafeDirectClientSecret: "qa_secret_yyy"
))
```

The SDK will print

```
[QuickAuth] ⚠️ UNSAFE mode: client_secret embedded; for trusted-enterprise only
```

on init. Do not use this for any public-distribution app.

---

## Domain-bound SMS autofill

The system keyboard shows a "From Messages" suggestion when a code is detected.
For the **domain-bound** form (`@yourdomain.com #123456`) you need:

1. **Associated Domains entitlement** in your target's signing capabilities:
   `webcredentials:yourdomain.com`
2. Host an `apple-app-site-association` file at:
   `https://yourdomain.com/.well-known/apple-app-site-association`

The SDK's `OneTimeCode.hasAssociatedDomainsEntitlement()` will best-effort
detect this and log a DEBUG warning if absent.

---

## Privacy

### Privacy manifest

The SDK ships `PrivacyInfo.xcprivacy` (SPM resource + CocoaPods resource
bundle), as App Store review requires from third-party SDKs. It declares the
phone number, device identifiers and conversion events the SDK sends, and the
required-reason code for its `UserDefaults` access (`CA92.1`).

It declares `NSPrivacyTracking = false` and lists **no** tracking domains,
because the SDK never reads the IDFA unless your app has already obtained ATT
authorisation, and because `api.quickauth.in` also serves OTP send/verify —
listing it as a tracking domain would have iOS block *authentication* for every
user who has not granted ATT. If your use of QuickAuth attribution is part of an
ad-measurement programme, that determination belongs in your own app's manifest
and App Privacy answers.

### App Tracking Transparency
The SDK respects ATT. It **never prompts** for tracking on its own. The
fingerprint sent for deferred-deep-link match only includes IDFA when
`ATTrackingManager.trackingAuthorizationStatus == .authorized`. Otherwise IDFA
is omitted entirely.

### DPDP / GDPR consent
Attribution and conversion calls require explicit consent:

```swift
QuickAuth.shared.consent.set(true)   // user opted in
QuickAuth.shared.consent.set(false)  // user opted out — calls return .consentRequired
```

Without consent, the SDK throws `QuickAuthError.consentRequired` for any
attribution call. OTP send/verify are **not** gated by consent because they
are required for authentication.

---

## Two usage modes

| Mode | When to use | API |
| --- | --- | --- |
| **Component** | Standard login screens; want brand polish for free | `QuickAuthLoginButton`, `QuickAuthOtpField`, UIKit equivalents |
| **Headless** | Custom UI; multi-step flows; non-standard layouts | `QuickAuth.shared.auth.initiate(...)`, `submitOtp(...)`, `resendOtp()`, `publishAutoReadCode(_:)` |

## Facade surface

`QuickAuth.shared` exposes `isInitialized`, `config`, `tokenManager`, `consent`,
`auth`, `attribution`, `whatsapp`, `setAuthEventHandler(_:)` and `reset()`.

---

## Backend endpoints

The SDK calls the QuickAuth backend (`api.quickauth.in` by default):

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/v1/sdk/session` | Mint a 10-min `sessionToken` (your backend; or SDK in unsafe mode) |
| POST | `/v1/sdk/auth/initiate` | Start an OTP session |
| POST | `/v1/sdk/auth/verify` | Verify the code, get JWT |
| POST | `/v1/sdk/attribution/launch` | Match deferred deep link |
| POST | `/v1/sdk/attribution/conversion` | Track conversion event |

All authenticated requests carry `Authorization: Bearer <sessionToken>` and an
`Idempotency-Key` header.

---

## Testing

```bash
swift test
```

Tests use a `URLProtocol` mock — no live network required. Covers:

- API client (auth header, idempotency, retries, JWT parsing, HTTP errors,
  `401 → invalidate + retry once`)
- TokenManager (single-flight refresh, expiry-aware refresh, JWT parsing,
  unsafe-direct mint)
- Consent gate (attribution & conversion blocked when consent is `false`)
- Fingerprint determinism + snake_case wire format
- OTP service (initiate/verify body shapes, event sequences, observer publisher)
- `resendOtp` (replays phone + channel + `autoSubmit`; throws with no attempt;
  cleared by `reset`)
- `autoSubmit` (off by default, fires with no subscriber present, one-shot latch,
  re-armed by a resend)
- Packaging (podspec derives its version from `Config.currentSDKVersion`;
  privacy manifest ships and parses)

## Releasing

The version lives in exactly one place: `Config.currentSDKVersion`. The podspec
reads that constant at pod-install time, and the SDK reports it in
`X-QuickAuth-SDK`. To cut a release, edit that line, then tag `v<version>` —
CocoaPods resolves the source from the tag, so publishing without it fails.

---

## License

MIT — see [LICENSE](./LICENSE).
