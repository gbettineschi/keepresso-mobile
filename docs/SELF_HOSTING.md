# Your own internet relay

Each owner hosts their own instance. There is no shared Keespresso service, subscription or account with this project. Nearby Bluetooth works independently. Internet uses a small Vercel Node24 API plus one Firebase project for Firestore storage and Android push. No virtual machine, inbound Mac port, router change, Tailscale or Wi-Fi pairing is needed.

## Create the free services

1. Create a dedicated Firebase project on Spark (no billing account). Analytics and Gemini are unnecessary. Create a **Standard** Firestore `(default)` database, ideally `europe-west3` near the relay's Frankfurt region. Select **Production mode**: the deny-all rules match `relay/firestore.rules`. Do not enable test-mode public access, TTL, backups or paid extensions.
2. Register Android package `io.github.gbettineschi.keepressomobile`. Download its public `google-services.json` configuration. Use its app ID, API key, project ID and project number as the four Android build properties in [android/README.md](../android/README.md). They initialize Firebase Messaging; they do not authorize Firestore access. The database remains deny-all for clients.
3. In Project settings → Service accounts, create a server credential for this dedicated project. Keep the downloaded private key out of git and app builds. The relay needs Firestore read/write and Firebase Cloud Messaging send access. Prefer an account limited to those roles when administering several services; the default Firebase Admin SDK account has broader Firebase access within this otherwise dedicated project. A leaked server key can access/delete ciphertext and abuse push, although it cannot decrypt device payloads or create valid device commands.
4. Create a Vercel Hobby project and link the `relay/` directory. The project is **Other**, Node24, Fluid Compute, Frankfurt. Production must be reachable without Vercel's interactive login because native clients use the relay's own credentials. Keep preview authentication enabled. For a Git integration, set Root Directory to `relay`; no Git integration is required for manual deployment.

## Configure and deploy

From `relay/`, after signing in to the official Vercel CLI:

```sh
vercel link --project keepresso-mobile --scope YOUR_ORGANIZATION_ID
npm ci
npm test
node scripts/configure.mjs --scope YOUR_ORGANIZATION_ID \
  --service-account /private/path/firebase-service-account.json \
  --private-dir /private/path/keespresso-relay
vercel deploy --prod --scope YOUR_ORGANIZATION_ID
```

The setup script verifies the linked organization, reads the service key locally, generates an independent random Mac bearer and sends only its hash to the server configuration. Secret values use stdin and are not printed. `--check-only` verifies the target/file without upload or generation. Existing environment values are never silently replaced. Keep the private Mac bearer file; it is not the phone pairing key. Vercel secrets are `FIREBASE_SERVICE_ACCOUNT` and `RELAY_MAC_TOKEN_SHA256`. Optional `RELAY_MAC_ID` limits the deployment to one Mac. Otherwise one owner may use isolated Mac IDs under the same deployment; this is not a public multi-tenant service.

Verify `/api/health` reports configured availability, and an unauthenticated POST to `/api/relay` returns401. Source files and private setup files must not be publicly served: only `relay/public` is a static output directory. Do not place credentials there. A healthy HTTP response is not an end-to-end phone test.

Build Android with the four Firebase properties, or set repository variables `FIREBASE_APPLICATION_ID`, `FIREBASE_API_KEY`, `FIREBASE_PROJECT_ID`, `FIREBASE_SENDER_ID` for this repository's CI. No Google service-account key belongs in Android or GitHub build variables. An optional stable development signing identity uses GitHub secrets `ANDROID_SIGNING_STORE_BASE64` and `ANDROID_SIGNING_PASSWORD`; app builds consume the four `KEESPRESSO_SIGNING_*` variables described in the Android README. Keep the same signing identity for updates. The old0.1.0 disposable CI signing identity was not preserved: an already installed0.1.0 APK may need one reinstall/re-pair. Subsequent builds using the persistent identity can update in place.

## Connect the existing pairing

1. In **Keespresso Mac → Internet**, enter the production HTTPS base URL and the private Mac bearer, then configure/enable Internet. The helper stores it in Keychain. No Keepresso session is started or settings changed.
2. Connect the already authorized phone nearby once. The helper enrolls that device and sends the URL and an access ticket through its encrypted Bluetooth connection. The phone derives relay credentials from its existing device key. There is no second QR or phone authorization.
3. Allow Android notifications for background reminders. Cloud Messaging registration is sent even when Bluetooth remains connected. The Android build must contain this Firebase project's public client configuration.
4. Open the phone dashboard away from Bluetooth. It performs a fresh authenticated status round trip before enabling controls. Expected command delay is a few seconds: Mac polling adds up to5s, with the next timer tick flushing its response. A cached snapshot stays stale; relay HTTP success alone cannot show the Mac as reachable.

Nearby is preferred automatically. A command picks one route and is never automatically resent after submission starts. The same ID/body and Mac journal protect against duplicates; a fresh read-only outcome lookup reconciles uncertainty. Notifications retain one durable ID across nearby and cloud, are encrypted, expire, and are claimed persistently before the phone posts them. Revoking the phone on the Mac blocks both paths locally immediately; remote cleanup is attempted separately.

## Saved configuration and recovery

After **Save and enable**, the helper stores the relay URL and Mac bearer in the macOS login Keychain, service `local.keespresso.companion.v1`, account `relay`. It reloads them on launch. Losing the original setup text file does not lose an already saved connection: **Enable saved relay** reuses it. The current helper has no export, reveal or server-key reset button. Before the first save, the private setup file is still needed.

To recover a saved bearer, use macOS Keychain Access, find that service/account, and authenticate to view the saved password; it is a JSON configuration containing the URL and bearer. Treat the whole value as a secret. A reinstall on the same Mac normally retains this Keychain entry, but erasing the Mac or deleting the entry does not. Phone pairing keys are separate Keychain records.

If every bearer copy and the Keychain entry are lost, generate a new independent random 32-byte Base64 bearer, replace Vercel's `RELAY_MAC_TOKEN_SHA256` with its SHA-256 hash, and redeploy. Enter the new bearer using the helper's existing **Save and enable** controls, then reconnect the authorized phone nearby to refresh its relay access ticket. This preserves the phone's pairing key. Vercel stores only the bearer's hash, so it cannot recover the original bearer. This reset currently requires the owner to update the server configuration; the Mac UI alone cannot reset it.

The separate Firebase service-account private key belongs only in Vercel's sensitive server configuration. It is not in the Mac setup file or Android app. If that server key is lost or compromised, create a replacement in Firebase, update `FIREBASE_SERVICE_ACCOUNT`, redeploy, and revoke the superseded key in Google Cloud IAM. Do not publish a key while recovering it.

## Free-tier budget and maintenance

For **one Mac awake24h/day and one phone dashboard open2h/day**, the5s polls total about562k requests/30days. One remote status every10s writes8640 documents/day. Empty command polls, enrollment validation and foreground phone polls use approximately28800 reads/day before occasional messages. Response/event mailboxes are capped32 perphone and expire; retained messages can add reads on subsequent polls until expiry. These are estimates, not measured usage guarantees.

Current published free allowances: Vercel Hobby1M invocations and CDN requests/month,4 active CPU-hours and360GB-hours; Firestore Spark50k reads/day,20k writes/day,1GiB storage; Firebase Messaging no cost. They are shared with other projects/apps in the account/project. Three continuously published phones would exceed Firestore's20k daily writes; do not assume the8-device authorization limit means8 always-on phones fit Spark. Hobby personal/noncommercial terms apply. Check [Vercel Hobby](https://vercel.com/docs/plans/hobby), [compute billing](https://vercel.com/docs/functions/usage-and-pricing), and [Firebase pricing](https://firebase.google.com/pricing) before deployment.

At562k requests/month, mean active CPU must stay below about25.6ms/request, and a2GB function's mean billed duration below about1.15s/request to fit those allowances before other usage. Short network requests are used rather than a permanently open Vercel connection. Validate this with actual metrics; first-request latency and warm-request latency differ. Firebase Admin authentication, database contention, an outage or quota exhaustion can still delay delivery. There is no automatic paid upgrade. The Mac helper creates no keep-awake lease just to maintain its network connection.

Maintenance is normal app/API dependency updates, occasional usage checks, and replacing a server key if it is compromised. Keep server credentials out of logs/backups you publish. The unmodified official Keepresso app continues updating normally; the bounded trigger observer remains pinned to its supported native version. Replacing Firestore/FCM or Vercel is possible through the transport/store boundary, but requires an adapter and verification; no unsupported alternate host is claimed ready.

Keep the services on **Vercel Hobby** and **Firebase Spark without a linked billing account** for stop-at-quota behavior. Neither automatically upgrades to a paid plan: an exhausted allowance blocks the affected service rather than adding overage charges. Firestore's daily quotas reset around midnight Pacific; Vercel's reset/pause period depends on the exceeded limit. Internet status, commands and push may fail while blocked, but nearby Bluetooth remains independent. Linking Firebase to a billing account upgrades it to Blaze, and Vercel Pro allows metered usage; spending alerts on paid plans are not equivalent to Spark/Hobby's no-overage behavior.

Vercel documents email/dashboard alerts as usage approaches or exceeds limits; check **Notifications → Usage increased** for the owner. Firebase budget emails concern a linked billing account and are not a reason to enable billing here. The inspected Spark project has general email alerts enabled, but its Cloud Firestore alert options cover insecure/expired rules, not quota warnings. Do not rely on a Firestore quota-warning email. Consult the Firebase Usage dashboard for quota consumption.

## Verification boundaries

Automated tests cover envelope interoperability/tampering, authorization, expiry, durable duplicate/uncertain outcomes, relay epochs, push retries, storage limits and route selection. Real Android notification permission, Google Play services, Doze/vendor battery restrictions, Bluetooth handoff, closed-lid Mac operation and native controls need actual-device acceptance in [ACCEPTANCE.md](ACCEPTANCE.md). Firebase accepting a push is not proof that a locked phone displayed it. Safe force-sleep and exact Celsius readings remain unavailable in this development build.
