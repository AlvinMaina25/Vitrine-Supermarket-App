# Notifications (Phase 7, backend only)

Order and payment events are written to an outbox table in the same transaction as the business
change. A separate worker sends them later through a real provider. Nothing here has a UI, and
**nothing has been applied or run yet**: the migration is written, the SQL test is written, no
provider has been called.

Files: `db/migrations/20261005160000_phase7_notifications_outbox.sql`,
`db/tests/phase7_notifications_outbox.test.sql`, `src/features/notifications/*`,
`src/routes/api.public.notifications-run.$token.ts`.

## Architecture

```
orders / payment_transactions ──AFTER trigger──▶ notification_outbox   (same transaction)
                                                      │
        cron ──POST /api/public/notifications-run/<token>──▶ worker run()
                                                      │
  claim_notifications ▶ provider lookup ▶ order + address lookup ▶ template ▶ provider.send
                                                      │
                                         complete_notification(sent | failed | dead | skipped_not_configured)
```

**Events** (all on the order owner): `order_created`, `payment_succeeded`, `payment_failed`,
`order_status_changed`, `order_delivered`, `order_refunded`. A status change to `delivered` or
`refunded` produces only its own event, and a change to `paid` produces none (`payment_succeeded`
covers it). `payment_status = refunded` also produces `order_refunded`; a partial refund does not.

**Channels**: `email`, `sms`, `whatsapp`. Email is always queued. SMS and WhatsApp are queued only
if the customer has a phone number on their profile at that moment (the number is not copied).

**Idempotency**: `dedupe_key = event_type:entity_id:channel`, `UNIQUE`, enforced by a CHECK so the key
cannot drift. Enqueue is `ON CONFLICT DO NOTHING`. `entity_id` is the order id (created, delivered,
refunded), the payment transaction id (payment events), or a deterministic id for one status
transition (`order_status_changed`, so each transition notifies once). A `sent` row can never
change again (trigger guard), so a replay cannot send it twice.

**Enqueue never blocks the business change**: the trigger catches any error, logs a WARNING with the
SQLSTATE only, and carries on. The cost: if enqueueing fails, that event is lost (there is no
retry of the trigger). Watch the database logs for `notification enqueue failed`.

**Statuses**

| status                   | meaning                                                                                |
| ------------------------ | -------------------------------------------------------------------------------------- |
| `pending`                | queued, not yet tried                                                                  |
| `processing`             | claimed by a worker (10-minute lease)                                                  |
| `sent`                   | a real provider **accepted** the message. Never set otherwise.                         |
| `failed`                 | last attempt failed, will retry: delay 30s × 2^(attempt−1), capped at 6h               |
| `skipped_not_configured` | no provider is connected for that channel. Nothing was looked up or sent.              |
| `dead`                   | gave up: 5 failed attempts, or a permanent error (bad request, no address, order gone) |

**Delivery is at-least-once.** If the worker dies after a provider accepted a message but before it
recorded `sent`, the lease expires and the row is sent again. Rare, but possible.

**Privacy**: rows hold `user_id`, `channel`, and ids (`order_id`, `transaction_id`) only; a CHECK
rejects any other payload key. The worker looks up the email (Supabase auth) or phone
(`profiles.phone`) at send time with the service role, in memory, for one send. Messages contain the
order number and, for status updates, the status label. No name, amount, payment method or link.
Logs contain event names, ids and counts only. Provider errors are stored as a short code such as
`http_503`, never a response body.

**Access**: no API role (anon, authenticated, service_role) has any privilege on the table; RLS is on
with no policy. The only paths in are functions:

| function                                          | callable by               | purpose                                                 |
| ------------------------------------------------- | ------------------------- | ------------------------------------------------------- |
| `claim_notifications(p_limit)`                    | service_role              | `FOR UPDATE SKIP LOCKED`, max 50                        |
| `complete_notification(id, outcome, error)`       | service_role              | record the real outcome                                 |
| `admin_list_notifications(status, limit, offset)` | admin (`require_admin()`) | ids, statuses, timing, counts                           |
| `get_my_notifications(limit)`                     | signed-in customer        | own rows: `id, event_type, channel, status, created_at` |

## Environment variables (server-side only, never `VITE_*`, never in the database)

All values below are placeholders. A channel is "configured" only when **every** required variable
for it is set and non-empty; otherwise its rows become `skipped_not_configured`.

```
# worker trigger (required to run the worker at all; at least 16 characters)
NOTIFICATIONS_RUN_TOKEN=<long-random-string>
SUPABASE_SERVICE_ROLE_KEY=<already used by payments>

# email: Resend
RESEND_API_KEY=<resend-api-key>
NOTIFY_EMAIL_FROM=<verified sender, e.g. shop@your-domain>

# sms: Africa's Talking
AT_USERNAME=<username>
AT_API_KEY=<api-key>
AT_SENDER_ID=<optional approved sender id>

# whatsapp: Meta WhatsApp Cloud API (approved template with ONE body variable)
WHATSAPP_ACCESS_TOKEN=<token>
WHATSAPP_PHONE_NUMBER_ID=<phone-number-id>
WHATSAPP_TEMPLATE_NAME=<approved-template-name>
WHATSAPP_TEMPLATE_LANG=<optional, default en>
```

The adapters follow each provider's public documentation but **have not been called**. Test each in
the provider's sandbox before trusting it. Phone numbers are treated as Kenyan (`07…`, `01…`,
`254…`); anything else becomes `dead` with `no_address`.

## Connect a provider

1. Apply the migration (manually) and run `db/tests/phase7_notifications_outbox.test.sql` on a dev database.
2. Create the provider account and set its variables in the server environment, then redeploy.
3. Send one test order and trigger the worker by hand (see cron below). Check `admin_list_notifications()`.
4. Rows queued **before** the provider existed are `skipped_not_configured`. They are not retried
   automatically (see replay).

**Do not connect SMS or WhatsApp until opt-in/opt-out preferences exist**: today every customer with
a phone number would receive them.

## Run the worker (cron)

```
curl -fsS -X POST "https://<your-domain>/api/public/notifications-run/<NOTIFICATIONS_RUN_TOKEN>"
```

Returns counts only, e.g. `{"claimed":3,"sent":2,"skippedNotConfigured":0,"failed":1,"dead":0}`.
A wrong token, wrong method or unset `NOTIFICATIONS_RUN_TOKEN` gives `404`. Each call handles up to
20 rows; schedule it every minute (cron, Supabase scheduled function, or any scheduler). Overlapping
calls are safe: a row is claimed by one run only.

## Replay dead (or skipped) rows

There is deliberately no API for this. In the SQL editor, as the database owner, inspect first:

```sql
select id, event_type, channel, attempts, last_error, created_at
  from public.notification_outbox where status = 'dead' order by created_at desc;
```

Then re-queue chosen rows (a `sent` row cannot be re-queued; the guard refuses):

```sql
update public.notification_outbox
   set status = 'pending', attempts = 0, next_attempt_at = now(), last_error = null
 where status = 'dead' and id in ('<id>', '<id>');
```

Replaying `skipped_not_configured` rows after connecting a provider works the same way. Restrict
by age (`created_at > now() - interval '1 day'`): customers should not receive week-old news.

## What is NOT done

- No notification UI, no admin screen, no customer-facing page for `get_my_notifications`.
- No provider account, no template/copy review (messages are neutral placeholders in `templates.ts`),
  no localisation, no links in messages.
- No opt-in / opt-out preferences; no quiet hours.
- No per-provider rate limiting beyond the 20-row batch.
- No automatic retry of a failed enqueue; no alerting on `dead` rows; no retention/cleanup job.
- No cron is scheduled; no SQL has been executed (test or migration); no provider has been called.
- Adapters are unverified against the live providers. WhatsApp business-initiated messages need an approved template.
- Not wired into `set_order_status`, `apply_payment_outcome`, `record_cod_payment` or `create_order`:
  the triggers observe their table changes, those functions are unchanged.
