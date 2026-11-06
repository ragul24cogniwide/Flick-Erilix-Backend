defmodule ChatServer.Conversations do
  @moduledoc "Direct and group chats and their membership rules."

  import Ecto.Query

  alias ChatServer.Accounts.{Device, User}
  alias ChatServer.Conversations.{Conversation, Member}
  alias ChatServer.{Messaging, Realtime, Repo}
  alias ChatServer.Messaging.{Delivery, Message}
  alias Ecto.Changeset
  alias Ecto.Multi

  @max_group_members 1024
  @max_title_length 100

  ## Creating

  @doc """
  Creates a conversation. Returns `{:ok, conversation, :created | :existing}`, where
  `:existing` means a direct chat between the two users was already there.
  """
  def create_conversation(%User{} = creator, params) do
    types = %{kind: :string, user_id: Ecto.UUID, title: :string, member_ids: {:array, Ecto.UUID}}

    changeset =
      {%{}, types}
      |> Changeset.cast(params, Map.keys(types))
      |> Changeset.validate_required([:kind])
      |> Changeset.validate_inclusion(:kind, ["direct", "group"])

    case Changeset.apply_action(changeset, :validate) do
      {:ok, %{kind: "direct"} = attrs} -> create_direct(creator, attrs, changeset)
      {:ok, %{kind: "group"}} -> create_group(creator, changeset)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp create_direct(_creator, attrs, changeset) when not is_map_key(attrs, :user_id) do
    {:error, Changeset.add_error(changeset, :user_id, "can't be blank")}
  end

  defp create_direct(%User{id: id}, %{user_id: id}, changeset) do
    {:error, Changeset.add_error(changeset, :user_id, "must be another user")}
  end

  defp create_direct(%User{} = creator, %{user_id: peer_id}, _changeset) do
    if users_exist?([peer_id]) do
      find_or_create_direct(creator, peer_id)
    else
      {:error, :user_not_found}
    end
  end

  defp find_or_create_direct(creator, peer_id) do
    direct_key = [creator.id, peer_id] |> Enum.sort() |> Enum.join(":")
    new = %Conversation{kind: :direct, created_by: creator.id, direct_key: direct_key}

    {:ok, %{conversation: conversation, status: status}} =
      Multi.new()
      |> Multi.insert(:inserted, new, on_conflict: :nothing, conflict_target: :direct_key)
      |> Multi.run(:conversation, fn repo, _changes ->
        {:ok, repo.get_by!(Conversation, direct_key: direct_key)}
      end)
      |> Multi.run(:status, fn repo, %{inserted: inserted, conversation: stored} ->
        if inserted.id == stored.id do
          insert_members(repo, stored.id, [creator.id, peer_id], :member)
          {:ok, :created}
        else
          {:ok, :existing}
        end
      end)
      |> Repo.transaction()

    conversation = Repo.preload(conversation, members: :user)
    if status == :created, do: notify_members(conversation)
    {:ok, conversation, status}
  end

  defp create_group(%User{} = creator, changeset) do
    changeset =
      changeset
      |> Changeset.validate_required([:title])
      |> Changeset.validate_length(:title, max: @max_title_length)
      |> Changeset.validate_length(:member_ids, max: @max_group_members - 1)

    with {:ok, attrs} <- Changeset.apply_action(changeset, :validate),
         other_ids = (Map.get(attrs, :member_ids, []) |> Enum.uniq()) -- [creator.id],
         true <- users_exist?(other_ids) || {:error, :user_not_found} do
      new = %Conversation{kind: :group, title: attrs.title, created_by: creator.id}

      {:ok, %{conversation: conversation}} =
        Multi.new()
        |> Multi.insert(:conversation, new)
        |> Multi.run(:members, fn repo, %{conversation: conversation} ->
          insert_members(repo, conversation.id, [creator.id], :admin)
          insert_members(repo, conversation.id, other_ids, :member)
          {:ok, nil}
        end)
        |> Repo.transaction()

      conversation = Repo.preload(conversation, members: :user)
      notify_members(conversation)
      {:ok, conversation, :created}
    end
  end

  defp users_exist?(user_ids) do
    Repo.aggregate(from(u in User, where: u.id in ^user_ids), :count) == length(user_ids)
  end

  defp insert_members(repo, conversation_id, user_ids, role) do
    joined_at = DateTime.utc_now()

    rows =
      Enum.map(user_ids, fn user_id ->
        %{conversation_id: conversation_id, user_id: user_id, role: role, joined_at: joined_at}
      end)

    repo.insert_all(Member, rows,
      on_conflict: :nothing,
      conflict_target: [:conversation_id, :user_id]
    )
  end

  ## Membership

  def member?(conversation_id, user_id) do
    Repo.exists?(
      from m in Member, where: m.conversation_id == ^conversation_id and m.user_id == ^user_id
    )
  end

  @doc "Adds a user to a group. Only admins may do this."
  def add_member(%User{} = actor, conversation_id, params) do
    types = %{user_id: Ecto.UUID}

    changeset =
      {%{}, types}
      |> Changeset.cast(params, [:user_id])
      |> Changeset.validate_required([:user_id])

    with {:ok, %{user_id: user_id}} <- Changeset.apply_action(changeset, :validate),
         {:ok, conversation} <- fetch_group_for_admin(conversation_id, actor.id),
         true <- users_exist?([user_id]) || {:error, :user_not_found},
         :ok <- ensure_group_has_room(conversation) do
      insert_members(Repo, conversation.id, [user_id], :member)
      conversation = Repo.preload(conversation, members: :user)
      notify_members(conversation)
      {:ok, conversation}
    end
  end

  @doc """
  Removes a user from a group. Admins may remove anyone and any member may leave,
  but a group that still has members must keep an admin.
  """
  def remove_member(%User{} = actor, conversation_id, user_id) do
    with {:ok, conversation_id} <- cast_id(conversation_id),
         {:ok, user_id} <- cast_id(user_id) do
      {:ok, result} =
        Repo.transaction(fn ->
          # The lock serializes removals, so two admins cannot both remove each other.
          from(c in Conversation, where: c.id == ^conversation_id, lock: "FOR UPDATE")
          |> Repo.one()
          |> remove_member_locked(actor.id, user_id)
        end)

      with {:ok, conversation} <- result do
        Messaging.forget_member_queue(conversation.id, user_id)
        conversation = Repo.preload(conversation, members: :user)
        notify_members(conversation)
        Realtime.notify_membership_changed([user_id])
        {:ok, conversation}
      end
    end
  end

  defp remove_member_locked(nil, _actor_id, _user_id), do: {:error, :not_found}
  defp remove_member_locked(%Conversation{kind: :direct}, _, _), do: {:error, :not_a_group}

  defp remove_member_locked(%Conversation{} = conversation, actor_id, user_id) do
    members = Repo.all(from m in Member, where: m.conversation_id == ^conversation.id)
    actor = Enum.find(members, &(&1.user_id == actor_id))
    target = Enum.find(members, &(&1.user_id == user_id))

    cond do
      is_nil(actor) -> {:error, :forbidden}
      actor.role != :admin and actor_id != user_id -> {:error, :forbidden}
      is_nil(target) -> {:error, :not_found}
      last_admin_with_others?(members, target) -> {:error, :last_admin}
      true -> delete_member(conversation, target)
    end
  end

  defp last_admin_with_others?(members, target) do
    admins = Enum.filter(members, &(&1.role == :admin))
    target.role == :admin and length(admins) == 1 and length(members) > 1
  end

  defp delete_member(conversation, target) do
    Repo.delete!(target)
    {:ok, conversation}
  end

  defp notify_members(conversation) do
    conversation.members |> Enum.map(& &1.user_id) |> Realtime.notify_membership_changed()
  end

  @doc "A user's conversations and the people they share one with, loaded in one query."
  def membership_snapshot(user_id) do
    rows =
      Repo.all(
        from mine in Member,
          left_join: other in Member,
          on: other.conversation_id == mine.conversation_id and other.user_id != ^user_id,
          where: mine.user_id == ^user_id,
          select: {mine.conversation_id, other.user_id}
      )

    %{
      conversation_ids: MapSet.new(rows, &elem(&1, 0)),
      peer_ids: for({_conversation_id, peer_id} <- rows, peer_id, into: MapSet.new(), do: peer_id)
    }
  end

  defp fetch_group_for_admin(conversation_id, user_id) do
    with {:ok, conversation_id} <- cast_id(conversation_id) do
      query =
        from c in Conversation,
          left_join: m in Member,
          on: m.conversation_id == c.id and m.user_id == ^user_id,
          where: c.id == ^conversation_id,
          select: {c, m}

      case Repo.one(query) do
        nil -> {:error, :not_found}
        {%Conversation{kind: :direct}, _member} -> {:error, :not_a_group}
        {conversation, %Member{role: :admin}} -> {:ok, conversation}
        {_conversation, _member} -> {:error, :forbidden}
      end
    end
  end

  defp ensure_group_has_room(conversation) do
    count =
      Repo.aggregate(from(m in Member, where: m.conversation_id == ^conversation.id), :count)

    if count < @max_group_members, do: :ok, else: {:error, :group_full}
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  ## Listing

  @doc """
  Lists the user's conversations, most recent activity first. Each entry has the last
  message's metadata (never its ciphertext) and the device's unread count.
  """
  def list_conversations(%User{} = user, %Device{} = device) do
    conversations =
      Repo.all(
        from c in Conversation,
          join: m in Member,
          on: m.conversation_id == c.id and m.user_id == ^user.id,
          preload: [members: :user]
      )

    ids = Enum.map(conversations, & &1.id)
    last_messages = last_messages(ids)
    unread_counts = unread_counts(ids, device.id)

    conversations
    |> Enum.map(fn conversation ->
      %{
        conversation: conversation,
        last_message: Map.get(last_messages, conversation.id),
        unread_count: Map.get(unread_counts, conversation.id, 0)
      }
    end)
    |> Enum.sort_by(&activity_time/1, {:desc, DateTime})
  end

  defp activity_time(%{last_message: %{inserted_at: inserted_at}}), do: inserted_at
  defp activity_time(%{conversation: conversation}), do: conversation.inserted_at

  defp last_messages(conversation_ids) do
    query =
      from m in Message,
        where: m.conversation_id in ^conversation_ids,
        distinct: m.conversation_id,
        order_by: [asc: m.conversation_id, desc: m.inserted_at, desc: m.id],
        select: %{
          id: m.id,
          conversation_id: m.conversation_id,
          sender_id: m.sender_id,
          kind: m.kind,
          inserted_at: m.inserted_at
        }

    query |> Repo.all() |> Map.new(&{&1.conversation_id, &1})
  end

  defp unread_counts(conversation_ids, device_id) do
    query =
      from d in Delivery,
        join: m in assoc(d, :message),
        where: m.conversation_id in ^conversation_ids,
        where: d.recipient_device_id == ^device_id and is_nil(d.read_at),
        group_by: m.conversation_id,
        select: {m.conversation_id, count()}

    query |> Repo.all() |> Map.new()
  end
end
