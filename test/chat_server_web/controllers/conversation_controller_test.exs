defmodule ChatServerWeb.ConversationControllerTest do
  use ChatServerWeb.ConnCase, async: true

  import ChatServer.Fixtures
  import Ecto.Query

  alias ChatServer.Conversations.Conversation
  alias ChatServer.Messaging.{Delivery, Message}
  alias ChatServer.Repo

  setup %{conn: conn} do
    alice = session_fixture()
    bob = session_fixture()
    %{conn: conn, alice: alice, bob: bob, carol: session_fixture()}
  end

  defp as(conn, session) do
    put_req_header(conn, "authorization", "Bearer #{session.access_token}")
  end

  defp member_ids(body), do: body["members"] |> Enum.map(& &1["user_id"]) |> Enum.sort()

  describe "direct conversations" do
    test "are unique per pair, whichever side creates them", ctx do
      params = fn peer -> %{kind: "direct", user_id: peer.user.id} end

      first =
        ctx.conn
        |> as(ctx.alice)
        |> post("/api/v1/conversations", params.(ctx.bob))
        |> json_response(201)

      again =
        ctx.conn
        |> as(ctx.alice)
        |> post("/api/v1/conversations", params.(ctx.bob))
        |> json_response(200)

      reverse =
        ctx.conn
        |> as(ctx.bob)
        |> post("/api/v1/conversations", params.(ctx.alice))
        |> json_response(200)

      assert first["id"] == again["id"]
      assert first["id"] == reverse["id"]
      assert member_ids(first) == Enum.sort([ctx.alice.user.id, ctx.bob.user.id])
      assert Repo.aggregate(Conversation, :count) == 1
    end

    test "need a real other user", ctx do
      conn = as(ctx.conn, ctx.alice)

      assert conn |> post("/api/v1/conversations", %{kind: "direct"}) |> response(422)

      assert conn
             |> post("/api/v1/conversations", %{kind: "direct", user_id: ctx.alice.user.id})
             |> response(422)

      assert %{"error" => "user_not_found"} =
               conn
               |> post("/api/v1/conversations", %{kind: "direct", user_id: Ecto.UUID.generate()})
               |> json_response(422)

      assert conn
             |> post("/api/v1/conversations", %{kind: "direct", user_id: "not-a-uuid"})
             |> response(422)
    end
  end

  describe "group conversations" do
    test "make the creator the only admin", ctx do
      body =
        ctx.conn
        |> as(ctx.alice)
        |> post("/api/v1/conversations", %{
          kind: "group",
          title: "Team",
          member_ids: [ctx.bob.user.id, ctx.alice.user.id, ctx.bob.user.id]
        })
        |> json_response(201)

      roles = Map.new(body["members"], &{&1["user_id"], &1["role"]})

      assert roles == %{ctx.alice.user.id => "admin", ctx.bob.user.id => "member"}
      assert body["title"] == "Team"
    end

    test "need a title and real members", ctx do
      conn = as(ctx.conn, ctx.alice)

      assert conn |> post("/api/v1/conversations", %{kind: "group"}) |> response(422)

      assert conn
             |> post("/api/v1/conversations", %{
               kind: "group",
               title: "Team",
               member_ids: [Ecto.UUID.generate()]
             })
             |> response(422)
    end

    test "reject an unknown kind", ctx do
      assert ctx.conn
             |> as(ctx.alice)
             |> post("/api/v1/conversations", %{kind: "channel"})
             |> response(422)
    end
  end

  describe "group admin actions" do
    setup ctx do
      %{group: group_fixture(ctx.alice, [ctx.bob])}
    end

    test "an admin can add and remove members", ctx do
      conn = as(ctx.conn, ctx.alice)
      path = "/api/v1/conversations/#{ctx.group.id}/members"

      body = conn |> post(path, %{user_id: ctx.carol.user.id}) |> json_response(200)
      assert ctx.carol.user.id in member_ids(body)

      assert conn |> delete("#{path}/#{ctx.carol.user.id}") |> response(204)
      assert conn |> delete("#{path}/#{ctx.carol.user.id}") |> response(404)
    end

    test "adding an existing member changes nothing", ctx do
      body =
        ctx.conn
        |> as(ctx.alice)
        |> post("/api/v1/conversations/#{ctx.group.id}/members", %{user_id: ctx.bob.user.id})
        |> json_response(200)

      assert %{"role" => "member"} =
               Enum.find(body["members"], &(&1["user_id"] == ctx.bob.user.id))
    end

    test "a plain member cannot add or remove others", ctx do
      conn = as(ctx.conn, ctx.bob)
      path = "/api/v1/conversations/#{ctx.group.id}/members"

      assert conn |> post(path, %{user_id: ctx.carol.user.id}) |> response(403)
      assert conn |> delete("#{path}/#{ctx.alice.user.id}") |> response(403)
    end

    test "an outsider cannot add or remove anyone", ctx do
      conn = as(ctx.conn, ctx.carol)
      path = "/api/v1/conversations/#{ctx.group.id}/members"

      assert conn |> post(path, %{user_id: ctx.carol.user.id}) |> response(403)
      assert conn |> delete("#{path}/#{ctx.bob.user.id}") |> response(403)
    end

    test "a member can leave", ctx do
      assert ctx.conn
             |> as(ctx.bob)
             |> delete("/api/v1/conversations/#{ctx.group.id}/members/#{ctx.bob.user.id}")
             |> response(204)
    end

    test "the last admin cannot leave while others remain", ctx do
      assert %{"error" => "last_admin"} =
               ctx.conn
               |> as(ctx.alice)
               |> delete("/api/v1/conversations/#{ctx.group.id}/members/#{ctx.alice.user.id}")
               |> json_response(422)
    end

    test "do not apply to direct chats", ctx do
      direct = direct_fixture(ctx.alice, ctx.bob)
      conn = as(ctx.conn, ctx.alice)
      path = "/api/v1/conversations/#{direct.id}/members"

      assert %{"error" => "not_a_group"} =
               conn |> post(path, %{user_id: ctx.carol.user.id}) |> json_response(422)

      assert %{"error" => "not_a_group"} =
               conn |> delete("#{path}/#{ctx.bob.user.id}") |> json_response(422)
    end

    test "report a malformed id as not found", ctx do
      conn = as(ctx.conn, ctx.alice)

      assert conn |> delete("/api/v1/conversations/nope/members/nope") |> response(404)

      assert conn
             |> post("/api/v1/conversations/nope/members", %{user_id: ctx.bob.user.id})
             |> response(404)
    end
  end

  describe "GET /conversations" do
    test "lists only my conversations, most recent first", ctx do
      older = direct_fixture(ctx.alice, ctx.bob)
      newer = direct_fixture(ctx.alice, ctx.carol)
      _not_mine = direct_fixture(ctx.bob, ctx.carol)

      message_fixture(ctx.alice, newer)
      message_fixture(ctx.alice, older)

      body = ctx.conn |> as(ctx.alice) |> get("/api/v1/conversations") |> json_response(200)

      assert Enum.map(body["conversations"], & &1["id"]) == [older.id, newer.id]
    end

    test "includes last message metadata without ciphertext", ctx do
      conversation = direct_fixture(ctx.alice, ctx.bob)
      _first = message_fixture(ctx.alice, conversation)
      last = message_fixture(ctx.bob, conversation)

      %{"conversations" => [summary]} =
        ctx.conn |> as(ctx.alice) |> get("/api/v1/conversations") |> json_response(200)

      assert summary["last_message"]["message_id"] == last.id
      assert summary["last_message"]["sender_id"] == ctx.bob.user.id
      refute Map.has_key?(summary["last_message"], "ciphertext")
    end

    test "counts unread messages for this device", ctx do
      conversation = direct_fixture(ctx.alice, ctx.bob)
      first = message_fixture(ctx.alice, conversation)
      message_fixture(ctx.alice, conversation)

      unread = fn session ->
        %{"conversations" => [summary]} =
          ctx.conn |> as(session) |> get("/api/v1/conversations") |> json_response(200)

        summary["unread_count"]
      end

      assert unread.(ctx.bob) == 2
      assert unread.(ctx.alice) == 0

      Repo.update_all(from(d in Delivery, where: d.message_id == ^first.id),
        set: [read_at: DateTime.utc_now()]
      )

      assert unread.(ctx.bob) == 1
    end

    test "shows a conversation with no messages", ctx do
      direct_fixture(ctx.alice, ctx.bob)

      assert %{"conversations" => [%{"last_message" => nil, "unread_count" => 0}]} =
               ctx.conn |> as(ctx.bob) |> get("/api/v1/conversations") |> json_response(200)
    end
  end

  describe "GET /conversations/:id/messages" do
    setup ctx do
      %{conversation: direct_fixture(ctx.alice, ctx.bob)}
    end

    defp messages_path(conversation), do: "/api/v1/conversations/#{conversation.id}/messages"

    test "a non-member cannot read", ctx do
      message_fixture(ctx.alice, ctx.conversation)

      assert %{"error" => "forbidden"} =
               ctx.conn
               |> as(ctx.carol)
               |> get(messages_path(ctx.conversation))
               |> json_response(403)
    end

    test "a removed member can no longer read", ctx do
      group = group_fixture(ctx.alice, [ctx.bob])
      message_fixture(ctx.alice, group)
      conn = as(ctx.conn, ctx.alice)

      assert conn
             |> delete("/api/v1/conversations/#{group.id}/members/#{ctx.bob.user.id}")
             |> response(204)

      assert ctx.conn |> as(ctx.bob) |> get(messages_path(group)) |> response(403)
    end

    test "a member added later cannot read earlier messages", ctx do
      group = group_fixture(ctx.alice, [ctx.bob])
      message_fixture(ctx.alice, group)

      ctx.conn
      |> as(ctx.alice)
      |> post("/api/v1/conversations/#{group.id}/members", %{user_id: ctx.carol.user.id})
      |> json_response(200)

      assert %{"messages" => []} =
               ctx.conn |> as(ctx.carol) |> get(messages_path(group)) |> json_response(200)
    end

    test "a sending device holds no copy of what it sent", ctx do
      message_fixture(ctx.alice, ctx.conversation)

      assert %{"messages" => []} =
               ctx.conn
               |> as(ctx.alice)
               |> get(messages_path(ctx.conversation))
               |> json_response(200)
    end

    test "returns ciphertext as sent", ctx do
      bytes = :crypto.strong_rand_bytes(32)

      message_fixture(ctx.alice, ctx.conversation, %{"ciphertext" => Base.encode64(bytes)})

      %{"messages" => [message]} =
        ctx.conn |> as(ctx.bob) |> get(messages_path(ctx.conversation)) |> json_response(200)

      assert Base.decode64!(message["ciphertext"]) == bytes
    end

    test "pages backwards through every message exactly once", ctx do
      sent = for _ <- 1..5, do: message_fixture(ctx.alice, ctx.conversation).id
      conn = as(ctx.conn, ctx.bob)
      path = messages_path(ctx.conversation)

      first = conn |> get(path, %{limit: "2"}) |> json_response(200)

      second =
        conn |> get(path, %{limit: "2", cursor: first["next_cursor"]}) |> json_response(200)

      third =
        conn |> get(path, %{limit: "2", cursor: second["next_cursor"]}) |> json_response(200)

      seen = Enum.flat_map([first, second, third], & &1["messages"])

      assert Enum.map(seen, & &1["message_id"]) == Enum.reverse(sent)
      assert length(third["messages"]) == 1
      assert third["next_cursor"] == nil
    end

    test "breaks timestamp ties without skipping messages", ctx do
      for _ <- 1..4, do: message_fixture(ctx.alice, ctx.conversation)
      tied_at = DateTime.utc_now()
      Repo.update_all(Message, set: [inserted_at: tied_at])

      conn = as(ctx.conn, ctx.bob)
      path = messages_path(ctx.conversation)

      first = conn |> get(path, %{limit: "2"}) |> json_response(200)

      second =
        conn |> get(path, %{limit: "2", cursor: first["next_cursor"]}) |> json_response(200)

      ids = Enum.map(first["messages"] ++ second["messages"], & &1["message_id"])

      assert length(Enum.uniq(ids)) == 4
    end

    test "hides messages whose ciphertext was cleared", ctx do
      message = message_fixture(ctx.alice, ctx.conversation)

      Repo.update_all(from(d in Delivery, where: d.message_id == ^message.id),
        set: [ciphertext: nil]
      )

      assert %{"messages" => []} =
               ctx.conn
               |> as(ctx.bob)
               |> get(messages_path(ctx.conversation))
               |> json_response(200)
    end

    test "rejects a bad cursor and a malformed id", ctx do
      conn = as(ctx.conn, ctx.bob)

      assert conn |> get(messages_path(ctx.conversation), %{cursor: "garbage"}) |> response(422)
      assert conn |> get("/api/v1/conversations/nope/messages") |> response(404)
    end
  end

  describe "POST /contacts/match" do
    defp phone_hash(phone), do: :sha256 |> :crypto.hash(phone) |> Base.encode16(case: :lower)

    test "returns only registered users, without phone numbers", ctx do
      known = phone_hash(ctx.bob.user.phone)

      %{"matches" => [match]} =
        ctx.conn
        |> as(ctx.alice)
        |> post("/api/v1/contacts/match", %{hashes: [known, phone_hash("+15550000001")]})
        |> json_response(200)

      assert match["hash"] == known
      assert match["user_id"] == ctx.bob.user.id
      refute Map.has_key?(match, "phone")
    end

    test "rejects bad input", ctx do
      conn = as(ctx.conn, ctx.alice)

      for hashes <- [nil, "abc", [1, 2], List.duplicate("x", 1001)] do
        assert conn |> post("/api/v1/contacts/match", %{hashes: hashes}) |> response(422)
      end
    end
  end
end
