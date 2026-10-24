# Recovery and reset

The setup can be rebuilt from the source and access to your own Google/Vercel accounts. The original setup text file is convenient, not irreplaceable. These procedures deliberately separate relay access, phone pairing and Android signing.

No recovery step needs a Keepresso session or a power command. Do not clear app data or phone pairing merely because an internet credential is missing. A relay outage/rotation interrupts internet status and reminders; nearby Bluetooth remains separate.

## Choose the smallest reset

| Situation | Procedure | Pairing / app rebuild |
| --- | --- | --- |
| Lost setup text, helper already configured | Reuse saved connection or recover from Keychain | Neither |
| Lost every Mac bearer copy | Rotate only the Mac bearer | Nearby reconnect; preserve pairing |
| Lost/compromised Firebase server JSON | Replace server key in Firebase/Vercel | Neither |
| Recreate Vercel project, keep Firebase | Deploy source into a new Vercel project | Update Mac URL; nearby reconnect |
| Replace Firebase project | Fresh cloud setup plus Android client configuration | Rebuild APK with same signing key; nearby reconnect |
| Mac/phone loses a pairing key | Revoke/forget old authorization, pair again | New local approval |
| Android signing private key lost | Recover signing store, or reinstall a new signed APK | A reinstall loses Android pairing/data |

## 1. Lost file, working/saved Mac configuration

Open **Keepresso Mobile** from Finder or the launcher, then find **Internet fallback** in its settings window. Closing that window hides it; use **Quit Keepresso Mobile** to stop the companion. A saved connection loads automatically. If it is disabled, use **Enable saved relay**. The blank bearer field is normal: it is not intended to reveal the stored secret.

For migration/recovery, open **Keychain Access** on that Mac. Search for service `local.keespresso.companion.v1`, account `relay`, in the user's login Keychain. Authenticate to view the saved password. It is JSON with `url` and `macBearer`; copy only the bearer into the helper's bearer field and the URL into its URL field. Keep the JSON private. The current helper has no export/reveal/server-reset button.

The `devices` entry under the same service holds phone authorization keys. Do not remove it to reset the relay. The Keychain entries are marked device-only; do not assume they will sync to a replacement Mac.

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
5. On the Mac, enter that URL and the **new** `mac-bearer.txt` value, then **Save and enable**. The helper stores it in Keychain. Vercel stores only its SHA-256 hash and cannot reconstruct a lost bearer.
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
2. Rebuild Android with the new project's four public client properties: `keepresso.firebase.applicationId`, `apiKey`, `projectId`, `senderId`. See [android/README.md](../android/README.md) for their complete names. Keep the same Android application ID and **signing identity** when updating the installed APK to preserve local pairing. Update GitHub repository variables too if using CI. A downloaded server JSON is never an Android build input.
3. Save the new relay URL/Mac bearer in the helper. Reconnect nearby so existing authorized phones receive the new relay ticket. Allow Android notifications and wait for push-token registration. Losing old Firestore mailboxes does not recover undelivered commands; uncertain mutations are not replayed.
4. Verify fresh status away from Bluetooth and an actual locked-phone reminder. Old encrypted mailbox data is not required to keep the existing device pairing.
5. Retire old service-account keys/deployments after verification. Deleting a Firebase project is optional and destructive; it is not required to reset the connection.

## 6. New Mac or phone; lost local pairing

If the Mac's `devices` Keychain entry or the phone's Keystore-backed app data is lost, that pairing cannot be recovered from the relay. In Android **Settings → Remove phone authorization**, confirm **Remove** to clear an obsolete local pairing. On the Mac use **Authorized phones → Revoke** for the obsolete phone record. Authorize the phone again with the Mac's new QR invitation and local approval. Do not restore a plaintext test key or treat a Firebase API key as phone authorization.

Reinstalling the helper on the same Mac can reuse its existing Keychain configuration, but erasing the Mac is different. A replacement Mac normally has a new local identity and needs a new pairing even if it uses the same owner-hosted relay.

If the Android signing private key is lost, the installed APK contains only its public certificate. It cannot recover the private key. A new signing identity requires uninstalling/reinstalling this development app and pairing again. Cloud credential rotation alone does not require losing Android app data.

## Troubleshooting and verification

| Symptom | Check / recovery |
| --- | --- |
| Health redirects to Vercel login | Allow production native-client access under Deployment Protection; keep relay authentication enabled |
| `configured:false` | Correct the two production variables, then deploy again |
| Mac relay authorization fails after rotation | Check target project/scope, new deployment, exact new bearer and its hash; do not change phone keys |
| Internet fails but nearby works | Check Vercel usage, Firestore quota, network and project status before resetting anything |
| Status works but no background alerts | Verify APK Firebase project settings, notification permission, token registration and Android battery policy |
| App shows stale data / unknown command outcome | Wait for fresh authenticated status or inspect the recorded outcome; never replay an uncertain mutation |
| CLI deployment is blocked by commit-author membership | Fix owner Git/Vercel membership or use the source-only manual deployment procedure below; do not forge Git authors |

### Source-only manual deployment fallback

An authenticated project owner can deploy a verified source copy without a Git integration. From the linked `relay/` directory, create a fresh staging directory outside Git and copy **only** `api/`, `src/`, `public/`, `package.json`, `package-lock.json`, `vercel.json`, `.vercelignore`, and `.vercel/project.json`. Do not copy `.env*`, server keys, the private setup directory, or `.git`. Run `npm ci`, `npm test`, then `vercel deploy --prod --scope YOUR_ORGANIZATION_ID` from that directory. Keep a record of the source commit and compare the copied source hashes before deployment. This is a manual owner deployment, not a change to repository authorship or a broader GitHub permission grant.

These procedures were checked against the existing source, UI labels and Vercel CLI 64.7.0. The token-generation example can be tested entirely in a temporary directory. Resetting the live credentials was intentionally not performed just to test the documentation.

## After a locally signed Mac update

Keep the same Applications path, bundle ID and Keychain service. Do not delete pairing keys or re-pair merely because an update cannot read them. An ad-hoc signed development build has a new signing requirement: macOS may ask for Keychain access to the existing companion items. From Mac 0.4.1, settings open before saved keys are read. The first read is noninteractive; if access is needed, use **Saved pairing → Unlock saved pairing…** and handle the system prompt in macOS. Reading keys never blocks the settings window or normal Quit. Connections and new pairing remain disabled until all saved credentials are read successfully; denial or invalid data does not replace saved credentials with an empty list. No password belongs in chat or setup files.

The already registered background launcher can also reject the new build with a code-signing failure, or report EX_CONFIG and a different registered parent build. Open the updated app and click **Refresh Follow Keepresso** if shown, then use **Manage automatic startup…** to approve in Login Items if macOS requests it. This action refreshes the old registered requirement only after the owner's click. It retains pairing and relay configuration. Until it is refreshed, a manually opened companion can run, but automatic startup/crash recovery is not established. Do not assume copying the app refreshed macOS approval.

Future trial updates replace the canonical bundle and update Android with the retained signing certificate; neither requires uninstalling or clearing phone data. The current ad-hoc Mac distribution may still need the above owner approvals after an update.
