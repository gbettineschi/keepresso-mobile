# Internet and background notifications

This guide describes the **iroh + direct Firebase** previews from 0.6.10. Older apps need the [legacy Vercel/Firestore guide](legacy/SELF_HOSTING.md) until both are updated and verified.

You do not deploy a server. iroh handles Internet connections through its public discovery and encrypted relay infrastructure. Firebase is only for waking Android to show notifications; status and controls do not pass through Firebase. Bluetooth works independently.

## What you need

- Both current apps, with the phone already approved on the Mac.
- An Apple silicon Mac on macOS 14.5+ and Android 9+ with Google Play services.
- A Google account and a dedicated Firebase project on **Spark**, with **no linked Cloud Billing account**. No payment card, Cloud Functions, Firestore or Analytics setup is needed.

Use your own project. The public repository does not provide a shared notification service or somebody else’s private sender key.

## 1. Prepare Firebase

Open the [Firebase console](https://console.firebase.google.com/). Create a dedicated project, or keep the project already used by your existing installation. Check **Usage and billing**: it must remain **Spark**. Do not upgrade to Blaze or link billing.

In **Project settings → Cloud Messaging**, check that **Firebase Cloud Messaging API (V1)** is enabled. If it is disabled, follow its API-management link and enable that API for this project. This is not a request to enable billing.

## 2. Download the Android client configuration

In **Project settings → General → Your apps**, add an Android app with this exact package:

`io.github.gbettineschi.keepressomobile`

Reuse the matching registration if it already exists. Download **google-services.json**. You do not need to rebuild a different APK for every Firebase project: the Mac supplies these public client settings to the paired phone over the encrypted connection. A SHA certificate is not needed for this FCM-only setup.

## 3. Create a private sender key

For the narrowest practical access, open the same project in [Google Cloud Console](https://console.cloud.google.com/), then **IAM & Admin → Service Accounts**:

1. Create a dedicated account, for example `keepresso-mobile-fcm`.
2. Grant **Firebase Cloud Messaging API Admin** (`roles/firebasecloudmessaging.admin`) on this project. Project Owner/Editor and Firestore access are not needed.
3. Open that account → **Keys → Add key → Create new key → JSON**.
4. Store the downloaded file privately outside this source checkout and shared folders. This is the secret file; do not send it to the phone, paste it into an issue, or commit it.

An organization can prohibit service-account keys. Do not weaken its policy to work around that; this local-key implementation then needs a different approved sender arrangement. The Firebase Admin SDK default service account may have broader access than this dedicated account.

## 4. Import on the Mac

Open the installed **Keepresso Mobile** settings window:

1. Enable **Internet fallback** under **Internet**.
2. Under **Phone notifications**, click **Import Firebase configuration…**.
3. Select the private service-account JSON, then the matching **google-services.json**.

Both files are validated before replacing the saved configuration. Cancellation or a project mismatch leaves the previous setup unchanged. The private key is stored only on this Mac. Replacing it does not reset pairing or the iroh identity.

Open Keepresso Mobile on the already-paired phone, near the Mac once. Its encrypted session learns the Internet identity and public Firebase options. No new QR scan is needed. Allow Android notifications if requested. If Android reports that a Firebase project change needs an app restart, reopen it; do not erase its data.

## 5. Verify the two paths separately

- **Internet:** outside Bluetooth range, open the phone app and confirm a fresh dashboard update. A lost route should show Unreachable, retaining last-known readings.
- **Notifications:** trigger one real reminder during a deliberately started native Keepresso session, then verify delivery with the phone app backgrounded and the phone locked. Do not confuse a foreground event with an FCM delivery test. Testing must not start an unwanted keep-awake session.

**Firebase configured** means only that the sender key was imported. **Phone registered** means the Mac has a token. **Accepted by Firebase** means Google accepted an event, not that Android displayed it. Android permissions, DND, volume, battery restrictions and network availability still affect presentation. High priority does not promise to bypass DND or silent mode.

## Updating an existing Vercel installation

Update both apps in place with their existing identities and keep the old services running. An authenticated nearby or legacy connection supplies the new iroh identity. Once that exact paired phone authenticates over iroh, the Mac can stop its legacy polling. Do not delete pairing to speed up migration.

Retire the dedicated Vercel deployment, its credentials and the old Firestore mailboxes only after Internet and locked-phone notification acceptance, and after confirming normal operation makes no legacy calls. **Keep the Firebase project, Android registration and FCM sender.** No cleanup is performed merely by reading this guide or importing files.

## Costs and recovery

FCM is a no-cost product; keep the project on Spark without billing. Rate limits can reject or delay traffic. See [quota and cost behavior](QUOTA_ALERTS.md). iroh’s public infrastructure is an external dependency, not your dedicated server or a guaranteed service; Bluetooth remains separate.

Lost key, lost configuration, new phone or corrupted storage: use [RECOVERY.md](RECOVERY.md). You can reconstruct setup from your Google account; the original download files are not your only recovery route.

Official references: [FCM authorization](https://firebase.google.com/docs/cloud-messaging/send/v1-api), [FCM IAM roles](https://firebase.google.com/docs/projects/iam/roles-predefined-product), [Firebase plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans).
