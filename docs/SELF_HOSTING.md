# Your own internet relay

Each owner hosts their own instance. There is no shared Keepresso service, subscription or account with this project. Nearby Bluetooth works independently. Internet uses a small Vercel Node24 API plus one Firebase project for Firestore storage and Android push. No virtual machine, inbound Mac port, router change, Tailscale or Wi-Fi pairing is needed.

Use this guide for a new installation. For lost credentials, replacing a deployment, or starting over, use [Recovery and reset](RECOVERY.md). Configure [quota email alerts](QUOTA_ALERTS.md) separately; they do not enable billing.

## Prerequisites and ownership

You need your own GitHub account/source checkout, a Google account that owns a dedicated Firebase project, and a Vercel Hobby account/team. Use Node.js 24, Git, and the official Vercel CLI. The deployment commands below were checked against Vercel CLI 64.7.0. Building the apps also needs the tools in [BUILDING.md](BUILDING.md).

```sh
git clone --branch feat/native-companion https://github.com/gbettineschi/keepresso-mobile.git
cd keepresso-mobile
npm install --global vercel@64.7.0
vercel login
vercel teams ls
```

The implementation currently lives on `feat/native-companion`; use a later documented release/ref when available. Fork the repository if you want your own Git integration or GitHub build settings. A fork is not required for a manual Vercel deployment.

In the commands below, replace `YOUR_ORGANIZATION_ID` with the Vercel team's ID, found under that team's **Settings → General**. Use the same scope for every command. Choose your own project name if `keepresso-mobile` is unavailable. Never copy another owner's Firebase identifiers or Mac bearer.

| Item | Where it belongs | Needed for recovery |
| --- | --- | --- |
| Source code / supported ref | GitHub or a local checkout | Can be downloaded again |
| Firebase server private key | Sensitive Vercel production environment variable | Can be replaced in Firebase; not recoverable from an APK |
| Independent Mac bearer | Private setup file, then Mac Keychain | Can be rotated without the Firebase private key |
| Phone pairing key | Mac Keychain and Android Keystore | Pair again if either device loses it |
| Firebase Android client settings | Gradle properties or GitHub repository variables | Can be downloaded again from Firebase |
| Android signing identity | Your private signing store and optional GitHub secrets | Required to update an installed APK without clearing its data |

## Create the free services

1. Create a dedicated Firebase project on Spark (no billing account). Analytics and Gemini are unnecessary. Create a **Standard** Firestore `(default)` database, ideally `europe-west3` near the relay's Frankfurt region. Select **Production mode**: the deny-all rules match `relay/firestore.rules`. Do not enable test-mode public access, TTL, backups or paid extensions.
2. Register Android package `io.github.gbettineschi.keepressomobile`. Download its public `google-services.json` configuration. Use its app ID, API key, project ID and project number as the four Android build properties in [android/README.md](../android/README.md). They initialize Firebase Messaging; they do not authorize Firestore access. The database remains deny-all for clients.
3. In Project settings → Service accounts, create a server credential for this dedicated project. Keep the downloaded private key out of git and app builds. The relay needs Firestore read/write and Firebase Cloud Messaging send access. Prefer an account limited to those roles when administering several services; the default Firebase Admin SDK account has broader Firebase access within this otherwise dedicated project. A leaked server key can access/delete ciphertext and abuse push, although it cannot decrypt device payloads or create valid device commands.
4. Create a Vercel Hobby project and link the `relay/` directory. The project is **Other**, Node24, Fluid Compute, Frankfurt. Production must be reachable without Vercel's interactive login because native clients use the relay's own credentials. Keep preview authentication enabled. For a Git integration, set Root Directory to `relay`; no Git integration is required for manual deployment.

## Configure and deploy

Create the project once, then link the `relay/` directory. For an existing project, skip `project create` and link that project instead:

```sh
cd relay
vercel project create keepresso-mobile --scope YOUR_ORGANIZATION_ID
vercel link --project keepresso-mobile --scope YOUR_ORGANIZATION_ID
npm ci
npm test
```

Check **Vercel → Project → Settings** before the first production deploy: Framework **Other**, Node.js **24.x**, Fluid Compute enabled, and the `public` output directory. `vercel.json` sets Frankfurt (`fra1`) and the 10-second API timeout. With a Git integration, the project root is `relay`; with CLI deployment, run the commands from that directory. Under **Deployment Protection**, production must allow native clients to reach the relay; previews can retain Vercel Authentication. The relay still enforces its own Mac/phone authentication.

Choose an absolute private directory **outside the source repository**, restrict it to your user, and put the downloaded Firebase server JSON there. For example, `/absolute/private/keepresso-relay` below is a placeholder you must replace. Keep credentials out of `relay/public`, GitHub variables, command arguments, chat, and build artifacts.

```sh
umask 077
mkdir -p /absolute/private/keepresso-relay
chmod 700 /absolute/private/keepresso-relay
chmod 600 /absolute/private/keepresso-relay/firebase-service-account.json
node scripts/configure.mjs --scope YOUR_ORGANIZATION_ID \
  --service-account /absolute/private/keepresso-relay/firebase-service-account.json \
  --private-dir /absolute/private/keepresso-relay --check-only
node scripts/configure.mjs --scope YOUR_ORGANIZATION_ID \
  --service-account /absolute/private/keepresso-relay/firebase-service-account.json \
  --private-dir /absolute/private/keepresso-relay
vercel deploy --prod --scope YOUR_ORGANIZATION_ID
```

The setup script verifies the linked organization, reads the service key locally, generates an independent random Mac bearer and sends only its hash to the server configuration. Secret values use stdin and are not printed. `--check-only` verifies the target/file without upload or generation. Existing environment values are never silently replaced. Keep the private Mac bearer file; it is not the phone pairing key. Vercel secrets are `FIREBASE_SERVICE_ACCOUNT` and `RELAY_MAC_TOKEN_SHA256`. Optional `RELAY_MAC_ID` limits the deployment to one Mac. Otherwise one owner may use isolated Mac IDs under the same deployment; this is not a public multi-tenant service.

Verify `/api/health` reports configured availability, and an unauthenticated POST to `/api/relay` returns401. Source files and private setup files must not be publicly served: only `relay/public` is a static output directory. Do not place credentials there. A healthy HTTP response is not an end-to-end phone test.

Use the stable production domain shown by Vercel, not a temporary preview URL. These checks disclose no credentials:

```sh
KEEPRESSO_RELAY_URL=https://your-production-domain.vercel.app
curl --fail --silent --show-error "$KEEPRESSO_RELAY_URL/api/health"
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' \
  --request POST --header 'Content-Type: application/json' \
  --data '{}' "$KEEPRESSO_RELAY_URL/api/relay"
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' \
  "$KEEPRESSO_RELAY_URL/.env.local"
```

Expect `{"version":1,"configured":true}`, then `401`, then `404`. A Vercel login page/redirect means deployment protection still blocks native clients. `configured:false` means a server variable is missing or invalid. After importing the Mac bearer into Keychain and verifying the connection, the transient Firebase JSON can be removed from the download/setup location; generating a replacement later is supported. Keep control of the Google and Vercel owner accounts.

If setup is interrupted, `vercel env ls production --scope YOUR_ORGANIZATION_ID` lists variable names without disclosing their values. Do not rerun initial setup assuming it will overwrite existing values: use the explicit update procedures in [RECOVERY.md](RECOVERY.md). Environment changes require a **new deployment** before running functions use them.

Build Android with the four Firebase properties, or set repository variables `FIREBASE_APPLICATION_ID`, `FIREBASE_API_KEY`, `FIREBASE_PROJECT_ID`, `FIREBASE_SENDER_ID` for this repository's CI. No Google service-account key belongs in Android or GitHub build variables. An optional stable development signing identity uses GitHub secrets `ANDROID_SIGNING_STORE_BASE64` and `ANDROID_SIGNING_PASSWORD`; app builds consume the four `KEEPRESSO_SIGNING_*` variables described in the Android README. Keep the same signing identity for updates. The old0.1.0 disposable CI signing identity was not preserved: an already installed0.1.0 APK may need one reinstall/re-pair. Subsequent builds using the persistent identity can update in place.

## Connect the existing pairing

1. In **Keepresso Mobile → Internet**, enter the production HTTPS base URL and the private Mac bearer, then configure/enable Internet. The helper stores it in Keychain. No Keepresso session is started or settings changed.
2. Connect the already authorized phone nearby once. The helper enrolls that device and sends the URL and an access ticket through its encrypted Bluetooth connection. The phone derives relay credentials from its existing device key. There is no second QR or phone authorization.
3. Allow Android notifications for background reminders. Cloud Messaging registration is sent even when Bluetooth remains connected. The Android build must contain this Firebase project's public client configuration.
4. Open the phone dashboard away from Bluetooth. It performs a fresh authenticated status round trip before enabling controls. Expected command delay is a few seconds: Mac polling adds up to5s, with the next timer tick flushing its response. A cached snapshot stays stale; relay HTTP success alone cannot show the Mac as reachable.

Nearby is preferred automatically. A command picks one route and is never automatically resent after submission starts. The same ID/body and Mac journal protect against duplicates; a fresh read-only outcome lookup reconciles uncertainty. Notifications retain one durable ID across nearby and cloud, are encrypted, expire, and are claimed persistently before the phone posts them. Revoking the phone on the Mac blocks both paths locally immediately; remote cleanup is attempted separately.

## Saved configuration and recovery

After **Save and enable**, the helper stores the relay URL and Mac bearer in the macOS login Keychain, service `local.keespresso.companion.v1`, account `relay`. It reloads them on launch. Losing the original setup text file does not lose an already saved connection: **Enable saved relay** reuses it. The current helper has no export, reveal or server-key reset button. Before the first save, the private setup file is still needed.

For an existing connection, lost credentials, or a new computer, follow [Recovery and reset](RECOVERY.md). This is a rebuildable setup: retaining multiple copies of the original text file is not required. Phone pairing and Android update signing have different recovery limits from replaceable server credentials.

If every bearer copy and the Keychain entry are lost, generate a new independent random 32-byte Base64 bearer, replace Vercel's `RELAY_MAC_TOKEN_SHA256` with its SHA-256 hash, and redeploy. Enter the new bearer using the helper's existing **Save and enable** controls, then reconnect the authorized phone nearby to refresh its relay access ticket. This preserves the phone's pairing key. Vercel stores only the bearer's hash, so it cannot recover the original bearer. This reset currently requires the owner to update the server configuration; the Mac UI alone cannot reset it.

The separate Firebase service-account private key belongs only in Vercel's sensitive server configuration. It is not in the Mac setup file or Android app. If that server key is lost or compromised, create a replacement in Firebase, update `FIREBASE_SERVICE_ACCOUNT`, redeploy, and revoke the superseded key in Google Cloud IAM. Do not publish a key while recovering it.

## Free-tier budget and maintenance

For **one Mac awake24h/day and one phone dashboard open2h/day**, the5s polls total about562k requests/30days. Background remote status every10s plus5s while that dashboard is open writes about9360 state documents/day. A read-only foreground demand/status request every60s keeps that faster state cadence; fresh authenticated snapshots maintain reachability within the same epoch. Its commands/responses and expiry cleanup add roughly480 writes/day for2h; allow about9840 writes and roughly33000–38000 reads before settings, reminders, retries and other traffic. Empty command polls, enrollment validation and foreground phone polls account for most reads. Response/event mailboxes are capped32 perphone and expire; retained messages can add reads on subsequent polls until expiry. These are estimates, not measured usage guarantees.

Current published free allowances: Vercel Hobby1M invocations and CDN requests/month,4 active CPU-hours and360GB-hours; Firestore Spark50k reads/day,20k writes/day,1GiB storage; Firebase Messaging no cost. They are shared with other projects/apps in the account/project. Three continuously published phones would exceed Firestore's20k daily writes; do not assume the8-device authorization limit means8 always-on phones fit Spark. Hobby personal/noncommercial terms apply. Check [Vercel Hobby](https://vercel.com/docs/plans/hobby), [compute billing](https://vercel.com/docs/functions/usage-and-pricing), and [Firebase pricing](https://firebase.google.com/pricing) before deployment.

At562k requests/month, mean active CPU must stay below about25.6ms/request, and a2GB function's mean billed duration below about1.15s/request to fit those allowances before other usage. Short network requests are used rather than a permanently open Vercel connection. Validate this with actual metrics; first-request latency and warm-request latency differ. Firebase Admin authentication, database contention, an outage or quota exhaustion can still delay delivery. There is no automatic paid upgrade. The Mac helper creates no keep-awake lease just to maintain its network connection.

Maintenance is normal app/API dependency updates, occasional usage checks, and replacing a server key if it is compromised. Keep server credentials out of logs/backups you publish. The unmodified official Keepresso app continues updating normally; the bounded trigger observer remains pinned to its supported native version. Replacing Firestore/FCM or Vercel is possible through the transport/store boundary, but requires an adapter and verification; no unsupported alternate host is claimed ready.

Keep the services on **Vercel Hobby** and **Firebase Spark without a linked billing account** for stop-at-quota behavior. Neither automatically upgrades to a paid plan: an exhausted allowance blocks the affected service rather than adding overage charges. Firestore's daily quotas reset around midnight Pacific; Vercel's reset/pause period depends on the exceeded limit. Internet status, commands and push may fail while blocked, but nearby Bluetooth remains independent. Linking Firebase to a billing account upgrades it to Blaze, and Vercel Pro allows metered usage; spending alerts on paid plans are not equivalent to Spark/Hobby's no-overage behavior.

Set up and verify [quota email alerts](QUOTA_ALERTS.md). Vercel provides its own usage emails. Firestore operation-quota warnings use Google Cloud Monitoring with the project's native quota-consumption metrics; they do not require a paid Firebase plan or an email service in the relay.

## Verification boundaries

Automated tests cover envelope interoperability/tampering, authorization, expiry, durable duplicate/uncertain outcomes, relay epochs, push retries, storage limits and route selection. Real Android notification permission, Google Play services, Doze/vendor battery restrictions, Bluetooth handoff, closed-lid Mac operation and native controls need actual-device acceptance in [ACCEPTANCE.md](ACCEPTANCE.md). Firebase accepting a push is not proof that a locked phone displayed it. Normal sleep requests are now implemented with verified native-hold release; physical sleep, alert audibility and haptics still require owner acceptance. CPU Celsius readings use the existing read-only SMC backend.
