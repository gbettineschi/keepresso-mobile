# Quota emails without enabling billing

Keep the relay on **Vercel Hobby** and its dedicated Firebase project on **Spark without a linked billing account**. The affected service stops at an exhausted free allowance; an email alert does not authorize an upgrade. No email provider, Mac background worker or Vercel cron is needed for the alerts below.

## Vercel

1. Select the team that owns the relay, then **Settings → My Notifications**.
2. Check the recipient shown under **Email** and enable **Email notifications**. Check that the relay project is not muted. Where the plan exposes a **Usage increased** preference, keep email enabled for it too.
3. Vercel sends its own approaching-limit/exceeded-limit email and dashboard notices. Hobby usage warnings are platform notices; the current Hobby notification page does not expose a separate configurable quota percentage.
4. On an exceeded Hobby allowance, check the **Usage** dashboard for the exhausted resource and its reset/pause period. Do not upgrade to Pro merely to restore service if you require no overage billing. Nearby Bluetooth remains separate.

Email preferences belong to the owner/team, not to the repository or an environment variable. Recheck them after moving the deployment to another team. Vercel can suppress an email if you already read the corresponding dashboard notification before the email was sent. See [plans](https://vercel.com/docs/plans) and [notification behavior](https://vercel.com/docs/notifications).

## Firebase / Firestore: 80% operation-quota warning

Firebase's project **Alerts** page does not provide a Firestore operation-quota email switch. Use **Google Cloud Monitoring**, in the same dedicated Firebase/Google Cloud project. This uses Google's own quota accounting and email channel, independently of the Mac and relay.

The warning covers the three daily **document operation allowances**: reads, writes and deletes. It does not claim to monitor every Firebase product, database storage, or monthly network allowance. Cloud Messaging is a no-cost product; its rate limits are separate from Firestore's daily operations.

For Spark's default limits, 80% is **40,000 reads**, **16,000 writes**, or **16,000 deletes**. The query reads the actual native limit values rather than hard-coding them. It uses `serviceruntime.googleapis.com/quota/rate/net_usage` with the Firestore operation-quota labels, so it does not rely on document-count dashboards that can omit empty-query reads.

### Create the email channel

1. In Google Cloud, select your Firebase project and open **Monitoring → Alerting → Manage notification channels**.
2. Under **Email**, select **Add New**. Enter your own receiving address and a display name such as **Keepresso owner quota alerts**, then **Save**.
3. Check that the email address is shown in the channels table. This saves the destination; it is not proof that a real incident email has arrived.

### Create the policy

1. In **Monitoring → Alerting**, select **Create policy** and switch the condition from **Builder** to **PromQL**. No initial metric selection is needed. The UI's accessible radio label may still say “Convert to MQL query” while its visible label is **PromQL**; use the visible PromQL mode.
2. Paste the expression below, replacing **both** `YOUR_FIREBASE_PROJECT_ID` occurrences with the project you own. A scoping project that includes unrelated projects must still filter to this one dedicated project.

```promql
max(
  sum by (project_id, quota_metric) (
    increase({"serviceruntime.googleapis.com/quota/rate/net_usage",
      monitored_resource="consumer_quota",
      project_id="YOUR_FIREBASE_PROJECT_ID",
      service="firestore.googleapis.com",
      quota_metric=~"firestore.googleapis.com/(read|write|delete)_operations_per_project"}[24h])
  )
  / on (project_id, quota_metric)
  min by (project_id, quota_metric) (
    last_over_time({"serviceruntime.googleapis.com/quota/limit",
      monitored_resource="consumer_quota",
      project_id="YOUR_FIREBASE_PROJECT_ID",
      service="firestore.googleapis.com",
      limit_name=~"(Read|Write|Delete)OperationsPerProjectPerDay"}[24h])
  )
) > 0.8
```

3. Preview a time range containing real relay activity. The underlying ratio should show the highest operation-quota fraction; below 80%, there is no firing alert. Do not interpret “no data” on a completely unused project as confirmed healthy monitoring. First make an ordinary authenticated status exchange, allow metrics to arrive, and inspect the native usage/limit series. Do not deliberately consume the quota to test an email.
4. Under **Configure trigger**, use **Retest window: 0 sec**, **Evaluation interval: 60 seconds**, and condition name **Firestore operation quota above 80% (rolling 24h)**.
5. Under **Notifications and name**, select the saved owner email channel. Use subject **Keepresso: Firestore quota above 80%**. Leave **Notify on alert closure** off. Set **Alert autoclose duration: 1 day** for missing data. Do not configure a re-notification interval.
6. Name the policy **Keepresso — Firestore quota 80%**. Include the rolling-window explanation below in its notification documentation. Review the recipient, threshold, interval and **Notify on alert open only**, then **Create policy**.
7. Verify the saved policy is **Enabled**, uses the intended channel and has the exact `> 0.8` expression. Save its policy URL for later editing. The [JSON template](examples/firestore-quota-policy.json) records the equivalent settings; replace the project/channel placeholders before using it with the official Monitoring API/tooling. The template is not an installed policy by itself.

Suggested notification documentation:

> One of this project's daily read, write or delete operation allowances exceeded 80% over the last 24 hours. This uses Google's quota-consumption counters. The rolling window can warn earlier than the midnight-Pacific daily reset. Check Firebase Usage before changing anything. Internet status, commands and reminders may stop at quota exhaustion; nearby Bluetooth remains independent. Keep Firebase on Spark without a billing account and Vercel on Hobby.

### Alternative when the console editor freezes

Google's [Cloud Shell](https://docs.cloud.google.com/shell/docs/launching-cloud-shell) includes the official CLI, so this does not require installing tools on the Mac. Open it from your project's Google Cloud header, or use the [temporary standalone session](https://shell.cloud.google.com/?ephemeral=true). Review Google's session authorization prompt yourself. Cloud Shell is a setup tool, not a relay dependency; close it after verification.

1. Check that the signed-in account owns the intended project. From the repository checkout, copy `docs/examples/firestore-quota-policy.json` into Cloud Shell as `firestore-quota-policy.json`. It contains no credentials. You can also upload the file using Cloud Shell's upload menu.
2. Replace every `YOUR_FIREBASE_PROJECT_ID` with your project ID and `YOUR_EMAIL_CHANNEL_ID` with the saved email channel's numeric ID. List the existing channels to identify it; avoid creating a duplicate:

   ```sh
   gcloud beta monitoring channels list --project=YOUR_FIREBASE_PROJECT_ID \
     --format='table(name,displayName,type,labels.email_address)'
   ```

3. Before creating anything, check for an already saved policy. An interrupted browser save might have succeeded:

   ```sh
   gcloud monitoring policies list --project=YOUR_FIREBASE_PROJECT_ID \
     --format='table(name,displayName,enabled)'
   ```

4. If there is no existing Keepresso quota policy, create it with the [official CLI command](https://docs.cloud.google.com/sdk/gcloud/reference/monitoring/policies/create):

   ```sh
   gcloud monitoring policies create --project=YOUR_FIREBASE_PROJECT_ID \
     --policy-from-file=firestore-quota-policy.json
   ```

5. Copy the returned policy resource name and read it back:

   ```sh
   gcloud monitoring policies describe \
     projects/YOUR_FIREBASE_PROJECT_ID/alertPolicies/YOUR_POLICY_ID \
     --project=YOUR_FIREBASE_PROJECT_ID --format=json
   ```

   Verify `enabled: true`, the intended channel, both project filters, `> 0.8`, `60s`, and `notificationPrompts: ["OPENED"]`. Reopen the policy in Monitoring to verify its saved state. Do not repeatedly run `create`: it creates additional policies. To repair an existing policy, use `gcloud monitoring policies update POLICY_RESOURCE --project=YOUR_FIREBASE_PROJECT_ID --policy-from-file=firestore-quota-policy.json`, then read it back again.

### Timing, repetition and limits

This is an **early warning over a rolling 24 hours**, not an exact “since midnight Pacific” total. A rolling day includes the current quota day plus part of the preceding one, so it can warn earlier; it avoids treating a smaller dashboard count as complete quota consumption. Metrics arrive with a delay, and Google/email delivery can add delay. A sudden burst can exhaust a quota before any email arrives. The hard no-billing limit remains the protection.

The query collapses reads/writes/deletes into one highest ratio. It opens one incident when any exceeds 80%, without hourly repeats or closure emails. Once usage falls below the threshold, a later new crossing can open a new incident and send a new warning. Missing data auto-closes after one day; absence of data is not proof of a reachable Mac or healthy relay.

Native metrics and this alert setup are available without linking a billing account in the inspected Spark project as of **2026-10-23**. The console currently shows zero alerting cost and announces alerting pricing changes for September 2027. Recheck [Monitoring pricing](https://cloud.google.com/products/observability/pricing) when maintaining the deployment; do not enable billing to keep a feature that later requires it. See Google's [quota alerting guide](https://docs.cloud.google.com/monitoring/alerts/using-quota-metrics), [Firestore quota limits](https://firebase.google.com/docs/firestore/quotas), and [dashboard accounting caveats](https://firebase.google.com/docs/firestore/monitor-usage).

## Verify delivery and recover the alerts

Check the policy's channel address, enabled state and query before assuming email delivery. An actual incident email is the end-to-end receipt evidence. If you use a temporary lower test threshold to verify delivery, label the subject as a test and restore **80%** immediately afterward; do not leave a test threshold active. Never create 40,000 reads just to trigger a test.

To change the recipient, edit/create the email channel in Monitoring and update the policy's selected channel. To rebuild a Firebase project, recreate both the channel and policy in that new project; notification-channel IDs are project-specific. Moving only Vercel leaves the Firebase alert policy intact. Recovering or rotating the Mac bearer does not change either platform's email settings.

The policy contains only quota metadata and a notification channel reference. It does not need your Mac bearer, phone pairing key, Firebase server JSON, or Android signing key. Do not attach any of those to an email, policy documentation, or public issue.
