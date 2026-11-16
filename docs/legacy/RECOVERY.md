> Legacy Vercel/Firestore setup for older installed builds. New setups use [iroh and direct Firebase](../SELF_HOSTING.md). Keep existing services until replacement acceptance.

# Recovery and reset

The setup can be rebuilt from the source and access to your own Google/Vercel accounts. The original setup text file is convenient, not irreplaceable. These procedures deliberately separate relay access, phone pairing and Android signing.

No recovery step needs a Keepresso session or a power command. Do not clear app data or phone pairing merely because an internet credential is missing. A relay outage/rotation interrupts internet status and reminders; nearby Bluetooth remains separate.

## Choose the smallest reset

| Situation | Procedure | Pairing / app rebuild |
| --- | --- | --- |
| Lost setup text, helper already configured | Reuse the saved private file; legacy Keychain is a migration fallback | Neither |
| Lost every Mac bearer copy | Rotate only the Mac bearer | Nearby reconnect; preserve pairing |
| Lost/compromised Firebase server JSON | Replace server key in Firebase/Vercel | Neither |
| Recreate Vercel project, keep Firebase | Deploy source into a new Vercel project | Update Mac URL; nearby reconnect |
| Replace Firebase project | Fresh cloud setup plus Android client configuration | Rebuild APK with same signing key; nearby reconnect |
| Mac/phone loses a pairing key | Revoke/forget old authorization, pair again | New local approval |
| Android signing private key lost | Recover signing store, or reinstall a new signed APK | A reinstall loses Android pairing/data |

## 1. Lost file, working/saved Mac configuration

Open **Keepresso Mobile** from Finder or the launcher, then find **Internet fallback** in its settings window. Closing that window hides it; use **Quit Keepresso Mobile** to stop the companion. A saved connection loads automatically. If it is disabled, use **Enable saved relay**. The blank bearer field is normal: it is not intended to reveal the stored secret.

For legacy recovery only, open **Keychain Access** on that Mac. Search for service `local.keespresso.companion.v1`, account `relay`, in the user's login Keychain. Authenticate to view the saved password. It is JSON with `url` and `macBearer`; copy only the bearer into the helper's bearer field and the URL into its URL field. Keep the JSON private. The current helper has no export/reveal/server-reset button.

The legacy `devices` entry under the same service holds the pre-migration phone authorization keys. After migration, Keychain records are retained but are not kept in sync; never restore them blindly after revocation or relay rotation. Do not remove it to reset the relay. The Keychain entries are marked device-only; do not assume they will sync to a replacement Mac.

## 2. Rotate a missing or compromised Mac bearer

This does **not** need the Firebase server private key. You need owner access to the existing Vercel project and a source checkout linked to it.

1. Disable Internet in the Mac helper while rotating. Keep nearby authorization.
2. Sign in to Vercel, enter the source `relay/` directory and link the correct project if necessary. Check `.vercel/project.json` contains the intended project/team IDs. Never guess the target from another checkout's defaults.
3. Choose an absolute private directory outside the repository. These commands create a new rotation subdirectory rather than overwrite an old bearer:

```sh
umask 077
KEEPRESSO_PRIVATE_DIR=/absolute/private/keepresso-relay
mkdir -p "$KEEPRESSO_PRIVATE_DIR"
chmod 700 "$KEEPRESSO_PRIVATE_DIR"
KEEPRESSO_ROTATION_DIR=$(mktemp -d "$KEEPRESSO_PRIVATE_DIR/rotation.XXXXXX")
node --input-type=module - "$KEEPRESSO_ROTATION_DIR" <<'NODE'
import {randomBytes, createHash} from 'node:crypto';
import {writeFileSync} from 'node:fs';
import {join} from 'node:path';
const directory = process.argv[2];
const bearer = randomBytes(32).toString('base64');
writeFileSync(join(directory, 'mac-bearer.txt'), bearer, {mode: 0o600, flag: 'wx'});
writeFileSync(join(directory, 'mac-token-sha256.txt'),
  createHash('sha256').update(bearer, 'utf8').digest('hex'), {mode: 0o600, flag: 'wx'});
NODE
vercel env update RELAY_MAC_TOKEN_SHA256 --environment production \
  --sensitive --yes --scope YOUR_ORGANIZATION_ID \
  < "$KEEPRESSO_ROTATION_DIR/mac-token-sha256.txt"
vercel deploy --prod --force --scope YOUR_ORGANIZATION_ID
```

4. Check the deployment is **Ready** and `/api/health` returns `configured:true` on the stable production domain.
5. On the Mac, enter that URL and the **new** `mac-bearer.txt` value, then **Save and enable**. The helper stores it in its private credential file. Vercel stores only its SHA-256 hash and cannot reconstruct a lost bearer.
6. Reconnect each already authorized phone nearby once. Its encrypted connection obtains a refreshed relay ticket using the same pairing key. Open the phone away from Bluetooth and wait for fresh authenticated status before using controls.

Changing the environment variable alone is insufficient: existing functions keep their old deployment's environment. If a bearer was compromised, also remove or protect old externally reachable deployments that retain the old hash; switching the production alias does not make their unique deployment URLs disappear. Do not roll back to an old credential-bearing deployment after a security rotation.

## 3. Replace the Firebase server private key

1. In the **same Firebase project**, open **Project settings → Service accounts → Firebase Admin SDK** and generate a new private key for the dedicated server account. Store the downloaded JSON privately outside the repo. This leaves Firestore data, public Android settings and phone pairing unchanged.
2. From the linked `relay/` directory, update the existing production secret using stdin:

```sh
vercel env update FIREBASE_SERVICE_ACCOUNT --environment production \
  --sensitive --yes --scope YOUR_ORGANIZATION_ID \
  < /absolute/private/keepresso-relay/new-firebase-service-account.json
vercel deploy --prod --force --scope YOUR_ORGANIZATION_ID
```

3. Verify **Ready**, configured health, and a fresh authenticated phone status exchange. Health alone checks configuration format, not database/push authorization.
4. In **Google Cloud → IAM & Admin → Service accounts → the server account → Keys**, identify and revoke the superseded key by its key ID. Do not delete the service account or unrelated keys. Keep the old key only until the new deployment works, unless responding to an active compromise. Existing short-lived access tokens may remain valid until they expire.
5. Remove the transient JSON from places you do not intend as private credential storage. The phone/Mac apps never need it. A future reset can generate a replacement again.

## 4. Replace only the Vercel deployment

1. Keep the existing Firebase project, database/rules and Android client registration.
2. Obtain a replacement Firebase server JSON if the old local copy was removed; use procedure 3 to retire the superseded key after verification.
3. Follow [SELF_HOSTING.md](SELF_HOSTING.md) to create/link a **new Hobby project**, configure its two production secrets and deploy the current `relay/` source. The initial setup script intentionally refuses to overwrite existing variables; it is appropriate for the new empty project.
4. Save the new stable production URL and its generated Mac bearer in the helper. Reconnect the same authorized phone nearby to receive the new URL/ticket. No Android rebuild is needed while the Firebase project/client settings stay the same.
5. Verify fresh remote status and an actual locked-phone reminder before retiring the old project. Retire old deployment access if this is a security reset. Do not delete the working deployment first.
6. Vercel notification preferences belong to the account/team, so check them for the destination team. Firebase quota alerts remain on the existing Google project.

## 5. Rebuild all cloud services from scratch

1. Follow [SELF_HOSTING.md](SELF_HOSTING.md) with a new dedicated Firebase **Spark** project and Vercel **Hobby** project. Set production deny-all Firestore rules; register the same Android package; configure/deploy the relay; configure [quota alerts](QUOTA_ALERTS.md).
2. Rebuild Android with the new project's four public client properties: `keepresso.firebase.applicationId`, `apiKey`, `projectId`, `senderId`. See [android/README.md](../../android/README.md) for their complete names. Keep the same Android application ID and **signing identity** when updating the installed APK to preserve local pairing. Update GitHub repository variables too if using CI. A downloaded server JSON is never an Android build input.
3. Save the new relay URL/Mac bearer in the helper. Reconnect nearby so existing authorized phones receive the new relay ticket. Allow Android notifications and wait for push-token registration. Losing old Firestore mailboxes does not recover undelivered commands; uncertain mutations are not replayed.
4. Verify fresh status away from Bluetooth and an actual locked-phone reminder. Old encrypted mailbox data is not required to keep the existing device pairing.
5. Retire old service-account keys/deployments after verification. Deleting a Firebase project is optional and destructive; it is not required to reset the connection.

## 6. New Mac or phone; lost local pairing

If the Mac's private pairing file and usable legacy `devices` entry, or the phone's Keystore-backed app data, are lost, that pairing cannot be recovered from the relay. In Android **Settings → Remove phone authorization**, confirm **Remove** to clear an obsolete local pairing. On the Mac use **Pairing → Remove paired device** and confirm the obsolete authorization. Authorize the phone again with the Mac's new QR invitation and local approval. Do not restore a plaintext test key or treat a Firebase API key as phone authorization.

Reinstalling the helper on the same Mac reuses its valid private credential file (or migrates legacy Keychain configuration once), but erasing the Mac is different. A replacement Mac normally has a new local identity and needs a new pairing even if it uses the same owner-hosted relay.

If the Android signing private key is lost, the installed APK contains only its public certificate. It cannot recover the private key. A new signing identity requires uninstalling/reinstalling this development app and pairing again. Cloud credential rotation alone does not require losing Android app data.

## Troubleshooting and verification

| Symptom | Check / recovery |
| --- | --- |
| Health redirects to Vercel login | Allow production native-client access under Deployment Protection; keep relay authentication enabled |
| `configured:false` | Correct the two production variables, then deploy again |
| Mac relay authorization fails after rotation | Check target project/scope, new deployment, exact new bearer and its hash; do not change phone keys |
| Internet works, nearby fails after a0.5 upgrade | Check app Settings → Connection → Permissions: ADVERTISE is newly required in addition to CONNECT. If Android retains a partial grant, the owner can toggle only this app's Nearby devices permission off/on; preserve pairing/data and global Bluetooth |
| Permission enabled in Settings but summary still blocked | Mac0.5.5+ automatically rechecks system flags when you return. Use Recheck for local folder/Steam access. Restart app is offered conditionally, but its real-process restart failed in the 0.5.5 owner trial; use a normal companion Quit/reopen if needed. If that does not help, investigate the signing requirement mismatch described in [Mac signing](../MAC_SIGNING.md). A narrowly scoped Accessibility reset requires owner approval and reauthorization; do not reset all privacy settings or remove pairing |
| Download trigger needs folder access | In Mac0.5.4+, foreground setup opens automatically for an unhandled build/scope. Use Continue and handle the macOS choices. To retry, open Review setup…; folder/Steam access is revalidated locally. The summary links to Privacy & Security after denial. Keep pairing; unapproved inputs stay unknown |
| Internet fails but nearby works | Check Vercel usage, Firestore quota, network and project status before resetting anything |
| Status works but no background alerts | Verify APK Firebase project settings, notification permission, token registration and Android battery policy |
| App shows stale data / unknown command outcome | Wait for fresh authenticated status or inspect the recorded outcome; never replay an uncertain mutation |
| CLI deployment is blocked by commit-author membership | Fix owner Git/Vercel membership or use the source-only manual deployment procedure below; do not forge Git authors |

### Source-only manual deployment fallback

An authenticated project owner can deploy a verified source copy without a Git integration. From the linked `relay/` directory, create a fresh staging directory outside Git and copy **only** `api/`, `src/`, `public/`, `package.json`, `package-lock.json`, `vercel.json`, `.vercelignore`, and `.vercel/project.json`. Do not copy `.env*`, server keys, the private setup directory, or `.git`. Run `npm ci`, `npm test`, then `vercel deploy --prod --scope YOUR_ORGANIZATION_ID` from that directory. Keep a record of the source commit and compare the copied source hashes before deployment. This is a manual owner deployment, not a change to repository authorship or a broader GitHub permission grant.

These procedures were checked against the existing source, UI labels and Vercel CLI 64.7.0. The token-generation example can be tested entirely in a temporary directory. Resetting the live credentials was intentionally not performed just to test the documentation.

## After a locally signed Mac update

From0.5.0, the authoritative saved connection is `~/Library/Application Support/Keespresso/Connection/credentials.json`. It contains both phone keys and relay configuration; the old spelling is intentional compatibility. The containing directory must be owned by your user with mode0700, the file a regular single-link file owned by you with mode0600, at most64KiB. Symlinks, wrong modes, malformed data and unsupported schemas fail closed. Do not edit the file to repair pairing or store it in source control. Other programs running as the same user can read it; FileVault protects data at rest before the disk is unlocked at startup; locking the screen after login does not restore that boundary. It does not protect against a process running as you.

On the first updated launch, an absent file causes a read of existing Keychain entries under the original silent policy. If approval is needed, **Pairing → Allow saved connection…** requests it through macOS. The complete migration must be written, read back and validated before any connection resumes. Denial/write failure leaves the old Keychain records intact and never opens an empty pairing slot. This one-time approval may still produce the old per-item OS prompts. A valid file makes all later launches and updates skip Keychain entirely, including interaction/status queries. A corrupt/insecure file does not fall back to Keychain automatically.

Normal updates replace the same `/Applications/Keepresso Mobile.app` and preserve its bundle ID, defaults, Application Support and Android data. No new QR is needed. Do not delete the credential file to solve a transport failure. Keep the rest of `~/Library/Application Support/Keespresso/` (including revocation records), and the helper's preferences/Mac identity, when making a private whole-machine backup. A credential-file copy alone is not a replacement-Mac migration procedure. If the file is lost, legacy Keychain can only restore its older state and may contain revoked devices or an obsolete bearer: inspect the history and retained revocation state before restoring. If current pairing keys are irrecoverable, use the explicit remove-and-pair process above; relay secrets alone can be rotated without a new pairing.

**Remove paired device** remains an explicit confirmed revocation. It saves an authoritative empty device list to the file, so restarting does not silently resurrect old Keychain devices. File integrity errors require recovery; they never grant new control or authorize an empty fallback. [Mac signing](../MAC_SIGNING.md) records the historical four-prompt cause and the optional certificate route; no paid setup is required here.

From Mac 0.4.3, open the canonical updated app normally. It registers its bundled startup agent automatically. A changed executable fingerprint, explicit signing failure or spawn-failed EX_CONFIG triggers a bounded unregister/register sequence. The executable fingerprint is recorded only after the app actually enters its managed background role. A failed launch gets 12 seconds for macOS to invalidate its stale launch rule, followed by at most one additional repair; persistent or unknown failure produces a warning. An enabled registration alone is never reported as a verified running background app. There is no Enable/Refresh button. **Open Login Items…** opens macOS's own controls; a blocked/required approval produces a warning. macOS may notify that a background item was added instead of asking a blocking question. If consent was revoked, the app leaves it revoked and asks the owner to enable it in Login Items. Failed repair stays visible and does not loop; quit/reopen the companion to retry after fixing the system state. A running managed agent never unregisters itself. Registration, Keychain access and an authenticated phone connection are separate states; do not infer one from another.

Pairing controls are in one section. Until saved keys load, **Allow saved connection…** occupies the first button position. When unpaired, **Show pairing QR code** is enabled; when paired, **Remove paired device** is enabled instead. Removal asks confirmation and revokes every listed legacy phone. On Android, remove the old authorization in the app's Settings before scanning a new QR so a fresh device identity is generated. Trial updates must not remove pairing or clear data as a recovery shortcut.

Future trial updates replace the canonical bundle and update Android with the retained signing certificate; neither requires uninstalling or clearing phone data. After a successful private-file migration, updates bypass Keychain; other macOS privacy/startup approvals remain OS-controlled.

### Optional Wi-Fi name access (Mac 0.4.4 / Android 0.4.1)

The Internet row checks the Mac's public HTTPS access independently of Bluetooth. Online requires a successful check; Offline means no usable route; Check failed means neither public check endpoint passed. A filter or endpoint outage can also cause Check failed. Checks update on a network change and about every 15 seconds while snapshots are requested, with no additional permanent polling timer. Old internet proof expires after 45 seconds. When the Mac is unreachable, dashboard values are last-known.

To show the current Wi-Fi name in Mac0.5.4+, open the installed Keepresso Mobile app and use its automatically presented setup (or **Review setup…**) → **Continue**. Handle the Location permission choice in macOS. This is optional: no coordinates are requested or read, and internet checking works without it. After denial, use the setup summary's **Open Settings…** for Location Services. Name unavailable means macOS did not supply a current SSID, not that internet is down. Ethernet and other active connections have their own labels. No Wi-Fi scanning or saved-network guesses.

Development verification can use `KeepressoMac --read-connectivity`, which performs a bounded read-only diagnostic before app startup, Keychain, Bluetooth, startup registration or power adapters. Its output can contain the current Wi-Fi name: keep diagnostic files private. It never requests Location permission. Do not normally open a staged companion bundle to test it, as normal startup manages its Login Item.
