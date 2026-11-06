# Chat server

A WhatsApp-style messaging backend in Elixir and Phoenix. The server is a fast router
of opaque encrypted payloads: it stores public keys and ciphertext, and does no
cryptography of its own. [SPEC.md](SPEC.md) has the full API and socket protocol.

## Run it

You only need Docker. Elixir runs in a container, and `bin/mix` runs any mix task there.

```sh
docker compose up           # Postgres and the API on http://localhost:4000
curl localhost:4000/health  # {"status":"ok"}
```

With Elixir 1.17+ and OTP 27+ installed, you can run the app on the host instead:

```sh
docker compose up db
mix setup
mix phx.server
```

In dev, sign-in codes are printed to the log. To try a sign-in:

```sh
curl -X POST localhost:4000/api/v1/auth/request_otp \
  -H 'content-type: application/json' -d '{"phone":"+15551234567"}'
docker compose logs web | grep 'sign-in code'
curl -X POST localhost:4000/api/v1/auth/verify_otp \
  -H 'content-type: application/json' \
  -d '{"phone":"+15551234567","code":"<code>","device":{"platform":"web"}}'
```

Connect to the socket at `ws://localhost:4000/socket/websocket?vsn=2.0.0&token=<access_token>`
and join `user:<your_user_id>`.

## Test

```sh
bin/mix test
bin/mix format --check-formatted
bin/mix credo --strict
```

## Deploy

```sh
cp .env.example .env        # then fill it in
docker compose -f docker-compose.prod.yml up -d --build
```

This builds the release, runs migrations on boot, and puts Caddy in front to obtain a
TLS certificate for `PHX_HOST`. Ports 80 and 443 must be reachable from the internet.

**Before going live, plug in an SMS provider.** Without one, `POST /auth/request_otp`
returns 503, so nobody can sign in. Implement the behaviour in
[sms_provider.ex](lib/chat_server/sms_provider.ex) and set it in `config/runtime.exs`.

**Push uses Firebase Cloud Messaging** when `FIREBASE_CREDENTIALS_BASE64` is set, and
only logs otherwise. Notifications read "New message" and never contain message content.
To check the credentials without notifying anyone, run
`ChatServer.PushProvider.Fcm.check_credentials()`.

### Environment variables

| Variable | Required | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | In prod | `ecto://USER:PASS@HOST/DATABASE` |
| `SECRET_KEY_BASE` | In prod | Signs tokens and keys OTP hashes. Generate with `openssl rand -base64 48`. Changing it signs everyone out and voids pending codes |
| `PHX_HOST` | In prod | Public hostname |
| `POOL_SIZE` | No (10) | Database connections per node. The Compose file sets 20 |
| `PORT` | No (4000) | HTTP port |
| `TRUST_PROXY` | No | Set to `true` only behind a proxy, so rate limits use `x-forwarded-for`. Clients can forge that header if nothing overwrites it |
| `MESSAGE_RETENTION` | No (`keep_metadata`) | After full delivery, `keep_metadata` clears the ciphertext and `delete_row` removes the message |
| `FIREBASE_CREDENTIALS_BASE64` | No | A base64-encoded Firebase service account. Turns on real push |
| `DB_HOST`, `DB_PORT` | No | Dev and test only: Postgres host and published port |

## Running many connections

Each socket uses one file descriptor, one Erlang port, and a few processes.

- **File descriptors:** set `ulimit -n` well above your target. `docker-compose.prod.yml`
  sets 1,048,576. For a non-Docker service, use `LimitNOFILE=1048576` in the systemd unit.
- **BEAM limits:** [rel/vm.args.eex](rel/vm.args.eex) sets `+Q 1048576` (ports) and
  `+P 5000000` (processes). Keep `+Q` at or below the file descriptor limit.
- **Linux kernel:** raise `net.core.somaxconn` and `net.ipv4.tcp_max_syn_backlog` for
  connection bursts, and `fs.file-max` if the system-wide limit is lower than your target.
- **Proxy:** each connection through a proxy uses an ephemeral port towards the app,
  about 28,000 per destination by default. Widen `net.ipv4.ip_local_port_range`, or run
  several app instances, to go beyond that. The proxy needs a high `ulimit -n` too.
- **Database:** the limit under load is usually Postgres, not sockets, because every
  send and ack is a write. Raise `POOL_SIZE` within Postgres's `max_connections`.
- **Memory:** budget from your own measurements. See the note under the table below.

## Load test

`scripts/run_load_test.sh` opens real WebSocket connections and exchanges messages
between pairs of users. It uses production settings and its own database.

```sh
scripts/run_load_test.sh --sockets 1000 --messages 5 --interval 1000
```

Measured on 2026-11-06 on an Apple M4 (10 threads), with Docker limited to about 8 GB
of memory, `POOL_SIZE=30`, and 256-byte messages. Each row is 1,000 sockets, all of which
joined in 0.2–0.3 s.

| Rate attempted | Messages | Rate achieved | Delivery p50 | Delivery p99 |
| --- | --- | --- | --- | --- |
| 1,000/s (9 runs) | 5,000 each | 830/s (limited by the script's pacing) | 1.3–2.9 ms | 3.9–16.8 ms in 6 runs, 75–415 ms in 3 |
| 5,000/s (1 run) | 10,000 | 4,118/s (saturated) | 230 ms | 499 ms |
| 20,000/s (1 run) | 20,000 | 4,409/s (saturated) | 3,233 ms | 3,505 ms |

In every run all messages were delivered and acknowledged, with 0 send errors, 0
duplicates, 0 unexpected disconnects, and no ciphertext left on the server afterwards.
Messages of 65,000 bytes also went through real sockets correctly in a smaller run.

**How to read this:** the server handles about 1,000 messages/s on this machine and
saturates at about 4,100–4,400/s. Past that point, messages queue and latency climbs, but
nothing was lost. At 1,000/s, a third of runs had a brief stall that pushed p99 to 75–415
ms. The cause has not been identified, and starting from a fresh database did not remove
it, so test on your production hardware before relying on p99 figures.

The client runs in the same VM as the server and Postgres runs in Docker on the same
machine, alongside other containers, so a dedicated server should differ. Memory read
450–700 KB per socket, but that includes the test client's own process and buffers, so
it overstates what the server uses. This tests 1,000 sockets only, not millions, and each
message here goes to one device, so groups will cost more per message.

## End-to-end encryption

Clients encrypt each message separately for every recipient device, using a proven
Signal-protocol library. The server stores each device's copy on its delivery row and
clears it as soon as that device acknowledges the message.

1. Fetch each member's devices and keys with `GET /keys/:user_id`, and set up a session
   per device. Each fetch uses up one of that device's one-time prekeys, so cache sessions.
2. Send `msg:send` with `ciphertexts: [{device_id, ciphertext}]`, with one entry per
   recipient device, including your own other devices.
3. If the reply is `device_mismatch`, nothing was stored. Fetch keys for the devices in
   `missing`, drop your sessions for those in `extra`, and send again with the same
   `client_msg_id`.

A device only becomes a recipient once it has uploaded keys with `PUT /keys`, so clients
should do that straight after signing in.

## Design notes and known limits

Choices the spec left open, and gaps to know about:

- **Offline senders miss receipts.** Receipts are sent live only. Delivered and read
  times are stored, but a sender who was offline at that moment is not told later.
- **Delivery is at-least-once.** A message is resent on reconnect until acked, so
  clients must dedupe by `message_id`.
- **`system` messages.** Clients cannot send `kind: "system"`, which stops one member
  forging a notice to others. The server does not generate any yet.
- **Multiple devices.** The sender's other devices receive each message too, so the
  client encrypts for them as well. A new device receives only messages sent after it
  signed in and uploaded keys.
- **Send limits.** A send is limited to 64 KB per device's copy and 3 MiB in total, so a
  long message to a very large group is rejected with `message_too_large`.
- **Recipients with no devices.** A message to someone with no signed-in device that has
  uploaded keys reaches no one, and only its metadata is stored.
- **Delivered metadata is never purged.** With `keep_metadata`, message and delivery
  rows stay after the ciphertexts are cleared. The daily job only removes undelivered
  messages, so add a retention rule if that metadata should not be kept indefinitely.
- **`delete_row` and read receipts.** Once a message is fully delivered its row is gone,
  so read receipts can no longer be recorded for it.
- **Open sockets outlive their token.** An access token is checked at connect. A socket
  stays open past the 15-minute expiry until the device logs out or disconnects.
- **Contact hashes are not private.** `POST /contacts/match` takes SHA-256 hashes of
  phone numbers as specified. Phone numbers are few enough to brute-force, so this stops
  casual exposure only.
- **Prekey draining.** `GET /keys/:user_id` is limited to 30 fetches a minute per user,
  and contact matching to 10. That slows one account from using up another user's
  one-time prekeys, but many accounts together could still do it.
- **Rate limits are per node.** With several nodes, the effective limit is multiplied by
  the node count. Presence and message routing work across a cluster.
- **Tokens in URLs.** The socket token is in the query string, as specified. Do not turn
  on proxy access logs that include query strings.
