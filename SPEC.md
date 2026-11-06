# Elixir chat backend: build spec for Claude Code

A WhatsApp-style messaging backend in Elixir and Phoenix. Save this as SPEC.md in an empty project folder, open Claude Code there, and paste the starter prompt from the last section.

## 1. Goal and scope

Build an MVP real-time chat server where the server is a fast router of opaque encrypted payloads, the same idea as WhatsApp.

### In scope

- Phone-number sign-in with a one-time code (OTP)
- 1-to-1 and group conversations
- Real-time delivery over WebSockets (Phoenix Channels)
- Offline queue: messages wait on the server until the recipient fetches them
- Delivery and read receipts (the ticks)
- Online/offline presence and typing indicators (never stored)
- Key server: stores public keys only, so clients can do end-to-end encryption
- Push-notification hook (stubbed behind a behaviour)

### Out of scope for the MVP

- Voice and video calls, media upload, stories, channels
- Writing any cryptography. The server treats message bodies as opaque bytes. Clients do the encryption using a proven Signal-protocol library. Never invent crypto.

## 2. Tech stack

| Piece | Choice |
| --- | --- |
| Language | Elixir 1.17 or newer on Erlang/OTP 27 or newer |
| Web framework | Phoenix 1.7 or newer, API only (`mix phx.new chat_server --no-html --no-assets --no-mailer`) |
| Database | PostgreSQL with Ecto |
| Real-time | Phoenix Channels, Phoenix.PubSub, Phoenix.Presence |
| Auth tokens | Phoenix.Token signed tokens (access token) plus a refresh token stored hashed in the database |
| Background jobs | Oban (cleanup of expired messages and OTPs) |
| Tests | ExUnit, Phoenix.ChannelTest, Phoenix.ConnTest |
| Quality | mix format, credo, dialyxir (optional), mix test must pass |

## 3. Data model

Use UUID primary keys and UTC timestamps. Add indexes on every foreign key and on the columns noted.

| Table | Columns | Notes |
| --- | --- | --- |
| users | id, phone (unique, E.164), display_name, about, inserted_at | |
| devices | id, user_id, platform (android/ios/web), push_token, last_seen_at | One user can have several devices |
| otp_codes | id, phone, code_hash, expires_at, attempts, consumed_at | Hash the code, 5-minute expiry, max 5 attempts |
| refresh_tokens | id, device_id, token_hash, expires_at, revoked_at | |
| identity_keys | id, device_id, identity_public_key, signed_prekey, signed_prekey_signature | Public parts only |
| one_time_prekeys | id, device_id, key_id, public_key, claimed_at | Claimed once, then marked used |
| conversations | id, kind (direct/group), title, created_by, inserted_at | Direct chats unique per user pair |
| conversation_members | conversation_id, user_id, role (member/admin), joined_at | Unique on (conversation_id, user_id) |
| messages | id, conversation_id, sender_id, sender_device_id, client_msg_id, ciphertext (bytea), kind (text/media_ref/system), inserted_at | Unique on (sender_id, client_msg_id) so retries never duplicate. Index on (conversation_id, inserted_at) |
| deliveries | message_id, recipient_device_id, delivered_at, read_at | One row per recipient device. Index on (recipient_device_id, delivered_at) where delivered_at is null |

Rule: the server never inspects ciphertext. Maximum size 64 KB per message, rejected otherwise.

## 4. REST API

All JSON, versioned under `/api/v1`. Everything except the auth routes needs `Authorization: Bearer <access_token>`.

| Method and path | Purpose |
| --- | --- |
| POST /auth/request_otp | Body: phone. Creates an OTP. In dev, print it to the log. In production, call the SmsProvider behaviour |
| POST /auth/verify_otp | Body: phone, code, device info. Returns access token, refresh token, user |
| POST /auth/refresh | Rotates the refresh token |
| POST /auth/logout | Revokes the current device session |
| GET /me and PATCH /me | Read and update the profile |
| POST /contacts/match | Body: list of hashed phone numbers. Returns which are registered users |
| PUT /keys | Upload identity key, signed prekey, and a batch of one-time prekeys |
| GET /keys/:user_id | Returns each device key bundle and atomically claims one one-time prekey per device |
| POST /conversations | Create a direct or group conversation |
| GET /conversations | List mine, with last message metadata and unread count |
| POST /conversations/:id/members and DELETE /conversations/:id/members/:user_id | Group admin actions |
| GET /conversations/:id/messages | Cursor pagination on messages still held by the server |
| POST /devices/push_token | Register or update the push token |

## 5. WebSocket protocol (Phoenix Channels)

Socket URL: `/socket`, authenticated with the access token in the connect params.

Channel `user:<user_id>` (one per connected device, joined automatically)

Client to server:

- `msg:send` with `{conversation_id, client_msg_id, ciphertext (base64), kind}`. Reply `{:ok, %{message_id, server_ts}}`, which is the single tick.
- `msg:ack_delivered` with `{message_ids}`
- `msg:ack_read` with `{conversation_id, up_to_message_id}`
- `typing:start` and `typing:stop` with `{conversation_id}`
- `presence:update` (online/away)

Server to client:

- `msg:new` with the full message payload
- `receipt:delivered` and `receipt:read` with `{message_id, by_user_id}`
- `typing` with `{conversation_id, user_id, state}`
- `presence_state` and `presence_diff` from Phoenix.Presence

Authorization: a user may only send to and read from conversations where they are a member. Check this on every event, not just on join.

## 6. Message flow the code must implement

1. The sender calls `msg:send`. The server validates membership and size, then inserts the message and one deliveries row per recipient device, in one database transaction. It replies with the single-tick ack.
2. For each recipient device that is online (tracked with Presence or the Registry), broadcast `msg:new` immediately.
3. For each device that is offline, leave the delivery pending and enqueue a push notification through the PushProvider behaviour. The push contains no message content.
4. When a device connects or joins its channel, send all pending deliveries in order, oldest first.
5. On `msg:ack_delivered`, set delivered_at, notify the sender with `receipt:delivered`, and when every recipient device has delivered, delete the ciphertext (keep metadata or delete the row, per config).
6. On `msg:ack_read`, set read_at and notify the sender with `receipt:read`.
7. A job runs daily and drops undelivered messages older than 30 days.

Typing and presence events are broadcast only. They must never touch the database.

## 7. Architecture guidelines

- Use Phoenix contexts: Accounts, Keys, Conversations, Messaging, Receipts. Controllers and channels stay thin and call contexts.
- Define behaviours SmsProvider and PushProvider with a logging implementation for dev and test, and a clear place to plug in real providers later.
- Use Ecto.Multi for multi-step writes. Handle duplicates through the unique client_msg_id index, so a retried send returns the original result.
- Let processes crash and rely on supervisors. Do not wrap everything in try/rescue.
- Configuration through environment variables in config/runtime.exs: DATABASE_URL, SECRET_KEY_BASE, PHX_HOST, POOL_SIZE, PORT.

## 8. Security requirements

- Serve over TLS only in production (terminate at nginx or Caddy, and enforce force_ssl).
- Rate-limit request_otp, verify_otp, and msg:send per user and per IP (a small Plug or an ETS-based limiter is fine).
- Hash OTP codes and refresh tokens. Never log phone numbers, codes, tokens, or ciphertext.
- Access tokens expire in 15 minutes. Refresh tokens expire in 30 days and rotate on use.
- Validate every payload with Ecto changesets or explicit schemas.
- Do not implement encryption in the server. Only store and serve public keys and opaque ciphertext.

## 9. Build phases and acceptance criteria

Complete one phase at a time. Run mix format and mix test after each, and commit.

- **Phase 1: Foundation.** Project setup, Docker Compose with Postgres, health endpoint GET /health, CI-ready mix test. Accepted when: docker compose up and mix phx.server work and the health route returns 200.
- **Phase 2: Auth.** Users, devices, OTP, tokens, refresh, logout. Accepted when: tests cover the full login flow, wrong or expired code, and OTP attempt limits.
- **Phase 3: Conversations.** Direct and group chats, membership rules, list endpoint. Accepted when: a user cannot read or send to a conversation they are not in (tested).
- **Phase 4: Real-time messaging.** Socket, user channel, msg:send, live delivery, offline queue, pending delivery on connect, idempotent sends. Accepted when: channel tests prove online delivery, offline then reconnect delivery, and no duplicates on retry.
- **Phase 5: Receipts, typing, presence.** Accepted when: sender receives delivered and read events, and typing never writes to the database.
- **Phase 6: Key server.** Key upload, bundle fetch, atomic one-time prekey claim. Accepted when: two concurrent fetches never receive the same one-time prekey (tested).
- **Phase 7: Cleanup and push hook.** Oban jobs for expiry, push stub wired to offline deliveries.
- **Phase 8: Release.** Dockerfile using mix release, docker-compose.prod.yml, README with setup, env vars, and the ulimit -n and BEAM tuning notes for many connections.

## 10. Definition of done

- Every phase accepted, all tests green, no compiler warnings
- A short README explaining how to run, test, and deploy
- A simple load script (for example with Phoenix.ChannelTest or a small Elixir client) that opens 1,000 sockets and sends messages, with the measured result written in the README

## 11. Starter prompt to paste into Claude Code

```
Read SPEC.md fully. Build this project phase by phase in the order given.
Before each phase, tell me the plan in a few lines. After each phase, run
mix format and mix test, fix any failures, then commit with a clear message.
Do not implement any cryptography. Ask me before adding any dependency not
listed in the spec. Start with Phase 1 and stop after Phase 2 for my review.
```
