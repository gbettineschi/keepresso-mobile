# Costs, limits and emails

For the new iroh + direct Firebase connection, keep Firebase on **Spark with no linked Cloud Billing account**. Do not enable Blaze, Cloud Functions or Firestore for this app.

**Firebase Cloud Messaging is a no-cost product**, rather than a paid message allowance with automatic overage charges. API limits can reject or delay delivery; this app uses bounded retries and discards expired events. Keeping billing unlinked avoids authorizing paid Google Cloud usage. [Firebase plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans), [FCM limits](https://firebase.google.com/docs/cloud-messaging/throttling-and-quotas).

There is no Firestore operation quota in the new data path. The previously configured **80% Firestore email alert** applies only while the legacy installation still uses that database. It is not an FCM delivery or notification-display monitor. There is no general built-in FCM “80% of free messages used” email switch to enable here.

If you receive an FCM quota error, inspect **APIs & Services → Firebase Cloud Messaging API → Quotas & System Limits** for the exact project. Optional Cloud Monitoring policies must target the actual exposed quota metric; this app does not install a monitoring worker or promise an email for every delivery failure. The Mac’s notification status distinguishes configuration, registration and Firebase acceptance.

Internet communication uses iroh’s public lookup/relay infrastructure. It is an external dependency and may impose availability or fair-use limits; the app does not provision a paid relay or authorize an upgrade. Bluetooth is independent. No Vercel allowance is consumed after completed migration.

Until the old deployment is retired, its Hobby limits and Firestore Spark quotas still matter. Keep the existing email preferences and 80% policy; the exact original instructions are preserved in [legacy quota alerts](legacy/QUOTA_ALERTS.md). Do not remove those alerts or cloud resources before replacement acceptance. Keep the Firebase project and FCM services afterward.
