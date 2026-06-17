# wuzapi media-retry patch

`mediaretry_wapatch.go` adds an optional **media retry** capability to a local
[wuzapi](https://github.com/asternic/wuzapi) build so whatsappel can ask a sender
to re-upload media whose WhatsApp CDN URL has expired (common for history that
predates the device link).

It adds:

- `POST /chat/mediaretry {"Id": "<message id>"}` — looks the message up in
  `message_history`, extracts its media key, and calls whatsmeow's
  `SendMediaRetryReceipt`.
- `handleMediaRetryEvent(...)` — on the asynchronous `events.MediaRetry` response,
  decrypts the notification and rewrites the stored message's `directPath` (and
  clears the dead `URL`) so a later download succeeds.

It is **best-effort**: it only works if the sender is online and still has the
media.

## Apply

1. Drop the file into your wuzapi checkout:

   ```
   cp mediaretry_wapatch.go /path/to/wuzapi/
   ```

2. Register the route — in `routes.go`, next to the other `/chat/*` routes:

   ```go
   s.router.Handle("/chat/mediaretry", c.Then(s.MediaRetryRequest())).Methods("POST")
   ```

3. Wire the async handler — in `wmiau.go`, in the `case *events.MediaRetry:` arm:

   ```go
   mycli.s.handleMediaRetryEvent(mycli.userID, evt)
   ```

4. Rebuild: `go build -o wuzapi .`

Then point the bridge at the same wuzapi and set `WHATSAPPEL_LIDMAP_DB`/run as
usual; the client's media-retry action (`R` on an expired media line) will work.

Pinned against whatsmeow `v0.0.0-20260516102357-8d3700152a69`; re-check the
`SendMediaRetryReceipt` / `DecryptMediaRetryNotification` signatures on upgrades.
