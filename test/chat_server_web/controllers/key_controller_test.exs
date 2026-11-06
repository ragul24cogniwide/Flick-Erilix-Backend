defmodule ChatServerWeb.KeyControllerTest do
  use ChatServerWeb.ConnCase, async: true

  import ChatServer.Fixtures
  import Ecto.Query

  alias ChatServer.Accounts
  alias ChatServer.Keys.{IdentityKey, OneTimePrekey}
  alias ChatServer.Repo

  setup %{conn: conn} do
    %{conn: conn, alice: session_fixture(), bob: session_fixture(keys: false)}
  end

  defp as(conn, session) do
    put_req_header(conn, "authorization", "Bearer #{session.access_token}")
  end

  defp b64(bytes), do: Base.encode64(bytes)

  defp identity(label \\ "a") do
    %{
      identity_public_key: b64("identity-#{label}"),
      signed_prekey: b64("signed-#{label}"),
      signed_prekey_signature: b64("signature-#{label}")
    }
  end

  defp prekeys(ids), do: Enum.map(ids, &%{key_id: &1, public_key: b64("prekey-#{&1}")})

  defp upload(conn, session, params) do
    conn |> as(session) |> put("/api/v1/keys", params)
  end

  defp fetch(conn, session, target) do
    conn |> as(session) |> get("/api/v1/keys/#{target.user.id}")
  end

  describe "PUT /keys" do
    test "stores keys and reports the prekeys available", ctx do
      body =
        upload(ctx.conn, ctx.bob, Map.put(identity(), :one_time_prekeys, prekeys(1..3)))
        |> json_response(200)

      assert body["one_time_prekeys_available"] == 3

      key = Repo.get_by!(IdentityKey, device_id: ctx.bob.device.id)
      assert key.identity_public_key == "identity-a"
    end

    test "replaces the identity key on re-upload, keeping one row", ctx do
      assert upload(ctx.conn, ctx.bob, identity("a")) |> response(200)
      assert upload(ctx.conn, ctx.bob, identity("b")) |> response(200)

      key = Repo.get_by!(IdentityKey, device_id: ctx.bob.device.id)
      assert key.signed_prekey == "signed-b"
    end

    test "can top up prekeys alone, ignoring ones it already has", ctx do
      assert upload(ctx.conn, ctx.bob, %{one_time_prekeys: prekeys(1..2)}) |> response(200)

      body =
        upload(ctx.conn, ctx.bob, %{one_time_prekeys: prekeys(2..4)}) |> json_response(200)

      assert body["one_time_prekeys_available"] == 4
    end

    test "rejects a partial identity key", ctx do
      assert upload(ctx.conn, ctx.bob, %{identity_public_key: b64("x")}) |> response(422)
    end

    test "rejects invalid input", ctx do
      invalid = [
        %{},
        %{identity() | signed_prekey: "not base64!"},
        %{identity() | signed_prekey: b64(:binary.copy(<<0>>, 4097))},
        %{one_time_prekeys: "nope"},
        %{one_time_prekeys: [%{key_id: "1", public_key: b64("x")}]},
        %{one_time_prekeys: [%{key_id: -1, public_key: b64("x")}]},
        %{one_time_prekeys: [%{key_id: 1, public_key: "not base64!"}]},
        %{one_time_prekeys: [%{key_id: 1}]},
        %{one_time_prekeys: prekeys(1..501)}
      ]

      for params <- invalid do
        assert upload(ctx.conn, ctx.bob, params) |> response(422),
               "expected #{inspect(params, limit: 3)} to be rejected"
      end
    end

    test "requires authentication", ctx do
      assert ctx.conn |> put("/api/v1/keys", identity()) |> response(401)
    end
  end

  describe "GET /keys/:user_id" do
    setup ctx do
      assert upload(ctx.conn, ctx.bob, Map.put(identity(), :one_time_prekeys, prekeys(1..2)))
             |> response(200)

      :ok
    end

    test "returns the bundle with a one-time prekey", ctx do
      device_id = ctx.bob.device.id

      assert %{"user_id" => user_id, "devices" => [bundle]} =
               fetch(ctx.conn, ctx.alice, ctx.bob) |> json_response(200)

      assert user_id == ctx.bob.user.id
      assert bundle["device_id"] == device_id
      assert Base.decode64!(bundle["identity_public_key"]) == "identity-a"
      assert Base.decode64!(bundle["signed_prekey"]) == "signed-a"
      assert Base.decode64!(bundle["signed_prekey_signature"]) == "signature-a"
      assert %{"key_id" => 1} = bundle["one_time_prekey"]
      assert Base.decode64!(bundle["one_time_prekey"]["public_key"]) == "prekey-1"
    end

    test "each fetch claims a different prekey, then returns none", ctx do
      claim = fn ->
        %{"devices" => [bundle]} = fetch(ctx.conn, ctx.alice, ctx.bob) |> json_response(200)
        bundle["one_time_prekey"]
      end

      assert %{"key_id" => 1} = claim.()
      assert %{"key_id" => 2} = claim.()
      assert claim.() == nil

      assert Repo.aggregate(
               from(p in OneTimePrekey, where: not is_nil(p.claimed_at)),
               :count
             ) == 2
    end

    test "returns one bundle per device", ctx do
      tablet = session_fixture(phone: ctx.bob.user.phone, keys: false)
      assert upload(ctx.conn, tablet, identity("t")) |> response(200)

      %{"devices" => bundles} = fetch(ctx.conn, ctx.alice, ctx.bob) |> json_response(200)

      assert bundles |> Enum.map(& &1["device_id"]) |> Enum.sort() ==
               Enum.sort([ctx.bob.device.id, tablet.device.id])
    end

    test "skips a device that has logged out", ctx do
      :ok = Accounts.logout(ctx.bob.device)

      assert %{"devices" => []} = fetch(ctx.conn, ctx.alice, ctx.bob) |> json_response(200)
    end

    test "returns no devices for a user who has uploaded nothing", ctx do
      no_keys = session_fixture(keys: false)

      assert %{"devices" => []} = fetch(ctx.conn, ctx.bob, no_keys) |> json_response(200)
    end

    test "is not found for an unknown or malformed user", ctx do
      conn = as(ctx.conn, ctx.alice)

      assert conn |> get("/api/v1/keys/#{Ecto.UUID.generate()}") |> response(404)
      assert conn |> get("/api/v1/keys/nope") |> response(404)
    end

    test "requires authentication", ctx do
      assert ctx.conn |> get("/api/v1/keys/#{ctx.bob.user.id}") |> response(401)
    end
  end
end
