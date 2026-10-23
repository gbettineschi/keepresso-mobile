# Android companion

The existing owner-approved BLE pairing is also the internet identity. After the Mac enrolls this phone with its relay, its next encrypted nearby session supplies the HTTPS URL and authentication ticket. Re-pairing is not required. A disabled or missing relay preserves the phone key.

## Optional Firebase configuration

Register an Android app with package `io.github.gbettineschi.keepressomobile` in the chosen Firebase project. Keep provider settings in local Gradle properties (for example `~/.gradle/gradle.properties`) or private CI inputs. These optional property names populate `FirebaseOptions` programmatically:

- `keespresso.firebase.applicationId`: Firebase Android app ID, not the package name
- `keespresso.firebase.apiKey`
- `keespresso.firebase.projectId`
- `keespresso.firebase.senderId`: Firebase messaging sender ID

No `google-services.json` is needed. With missing configuration, foreground internet status can work, but Settings explicitly reports that background internet reminders are unavailable. Notification permission is needed to post reminders. Denying it does not disable foreground status. Denying Nearby Devices permission does not disable a previously configured internet route.

The app polls every five seconds while visible and not authenticated nearby. Explicit commands may poll acknowledgements at one second for no more than thirty seconds. Background delivery uses encrypted FCM data messages, or one bounded authenticated mailbox fetch for a content-free hint. There is no permanent background HTTP poll or data-sync foreground service.

A mutation has one request ID and exact body across route selection. Its intent and uncertainty are saved with Android Keystore encryption before transmission. Failures never choose another route or replay a mutation. Fresh read-only `operation_status` queries reconcile saved outcomes; `not_found` leaves the outcome uncertain. Event claims are committed before either BLE or FCM can notify. Claims, snapshots, and command records are excluded from backup.

## Verification

`./gradlew -PcoreOnly :core:test` runs the JVM protocol/security suite with JDK 17 and no Android SDK. `./gradlew :core:test :app:lintDebug :app:assembleDebug` additionally requires Android SDK 35. Tests use fixture keys, fake power behavior, and local HTTPS servers. Physical BLE handoff, Android permission behavior, closed-lid delivery and locked-phone FCM notifications still require real-device acceptance.
