defmodule ChatServer.Keys do
  @moduledoc """
  The key server. It stores and hands out public keys as opaque bytes so clients can
  run the Signal protocol themselves. It performs no cryptography, and does not check
  signatures: clients verify those.
  """

  import Ecto.Query

  alias ChatServer.Accounts
  alias ChatServer.Accounts.{Device, User}
  alias ChatServer.Keys.{IdentityKey, OneTimePrekey}
  alias ChatServer.Repo
  alias Ecto.Changeset
  alias Ecto.Multi

  @identity_fields [:identity_public_key, :signed_prekey, :signed_prekey_signature]
  # Generous enough for post-quantum keys, small enough to stop abuse as free storage.
  @max_key_bytes 4096
  @max_prekey_batch 500
  @max_key_id 2_147_483_647

  ## Uploading

  @doc """
  Stores this device's identity key and any new one-time prekeys. Either part may be
  omitted to top up prekeys or rotate the signed prekey. Returns how many unclaimed
  prekeys the device now has. Re-sending a known `key_id` leaves that prekey unchanged.
  """
  def upload_keys(%Device{} = device, params) do
    with {:ok, attrs} <- validate_upload(params) do
      {:ok, %{available: available}} =
        Multi.new()
        |> put_identity(device, attrs)
        |> Multi.run(:prekeys, fn repo, _changes ->
          {:ok, insert_prekeys(repo, device, attrs.one_time_prekeys)}
        end)
        |> Multi.run(:available, fn repo, _changes -> {:ok, count_available(repo, device)} end)
        |> Repo.transaction()

      {:ok, available}
    end
  end

  defp put_identity(multi, _device, %{identity: nil}), do: multi

  defp put_identity(multi, device, %{identity: identity}) do
    Multi.insert(multi, :identity, struct(%IdentityKey{device_id: device.id}, identity),
      on_conflict: {:replace, @identity_fields ++ [:updated_at]},
      conflict_target: :device_id
    )
  end

  defp insert_prekeys(repo, device, prekeys) do
    now = DateTime.utc_now()

    rows =
      Enum.map(prekeys, fn prekey ->
        %{
          id: Ecto.UUID.generate(),
          device_id: device.id,
          key_id: prekey.key_id,
          public_key: prekey.public_key,
          inserted_at: now
        }
      end)

    repo.insert_all(OneTimePrekey, rows,
      on_conflict: :nothing,
      conflict_target: [:device_id, :key_id]
    )
  end

  defp count_available(repo, device) do
    repo.aggregate(
      from(p in OneTimePrekey, where: p.device_id == ^device.id and is_nil(p.claimed_at)),
      :count
    )
  end

  defp validate_upload(params) do
    types = Map.new(@identity_fields, &{&1, :string})

    changeset =
      {%{}, types}
      |> Changeset.cast(params, @identity_fields)
      |> validate_identity_complete()

    Enum.reduce(@identity_fields, changeset, &decode_key(&2, &1))
    |> Changeset.apply_action(:validate)
    |> with_prekeys(params)
  end

  defp validate_identity_complete(changeset) do
    if Enum.any?(@identity_fields, &Changeset.get_change(changeset, &1)) do
      Changeset.validate_required(changeset, @identity_fields)
    else
      changeset
    end
  end

  defp decode_key(changeset, field) do
    Changeset.validate_change(changeset, field, fn ^field, encoded ->
      case decode_key_bytes(encoded) do
        {:ok, _bytes} -> []
        :error -> [{field, "must be base64, at most #{@max_key_bytes} bytes"}]
      end
    end)
  end

  defp decode_key_bytes(encoded) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} when byte_size(bytes) in 1..@max_key_bytes -> {:ok, bytes}
      _invalid -> :error
    end
  end

  defp decode_key_bytes(_encoded), do: :error

  defp with_prekeys({:error, changeset}, _params), do: {:error, changeset}

  defp with_prekeys({:ok, identity}, params) do
    with {:ok, prekeys} <- validate_prekeys(Map.get(params, "one_time_prekeys", [])) do
      if map_size(identity) == 0 and prekeys == [] do
        {:error, :no_keys}
      else
        {:ok, %{identity: decode_identity(identity), one_time_prekeys: prekeys}}
      end
    end
  end

  defp decode_identity(identity) when map_size(identity) == 0, do: nil
  defp decode_identity(identity), do: Map.new(identity, fn {k, v} -> {k, Base.decode64!(v)} end)

  defp validate_prekeys(prekeys) when is_list(prekeys) and length(prekeys) <= @max_prekey_batch do
    prekeys
    |> Enum.reduce_while([], fn prekey, valid ->
      case validate_prekey(prekey) do
        {:ok, prekey} -> {:cont, [prekey | valid]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :invalid_prekeys}
      valid -> {:ok, Enum.uniq_by(valid, & &1.key_id)}
    end
  end

  defp validate_prekeys(_prekeys), do: {:error, :invalid_prekeys}

  defp validate_prekey(%{"key_id" => key_id, "public_key" => encoded})
       when is_integer(key_id) and key_id in 0..@max_key_id do
    case decode_key_bytes(encoded) do
      {:ok, public_key} -> {:ok, %{key_id: key_id, public_key: public_key}}
      :error -> :error
    end
  end

  defp validate_prekey(_prekey), do: :error

  ## Fetching

  @doc """
  Returns a key bundle per signed-in device of a user, claiming one one-time prekey
  from each. A device out of prekeys gets `one_time_prekey: nil`, which the Signal
  protocol allows for.
  """
  def fetch_bundles(user_id) do
    with {:ok, user_id} <- cast_id(user_id),
         true <- Repo.exists?(from u in User, where: u.id == ^user_id) || {:error, :not_found} do
      {:ok, bundles} =
        Repo.transaction(fn ->
          user_id |> identity_keys() |> Enum.map(&bundle/1)
        end)

      {:ok, bundles}
    end
  end

  defp identity_keys(user_id) do
    Repo.all(
      from k in IdentityKey,
        join: d in Device,
        as: :device,
        on: d.id == k.device_id,
        where: d.user_id == ^user_id,
        where: exists(Accounts.active_session_query())
    )
  end

  defp bundle(%IdentityKey{} = key) do
    %{
      device_id: key.device_id,
      identity_public_key: key.identity_public_key,
      signed_prekey: key.signed_prekey,
      signed_prekey_signature: key.signed_prekey_signature,
      one_time_prekey: claim_prekey(key.device_id)
    }
  end

  # The row lock makes the claim atomic. SKIP LOCKED means a concurrent fetch moves on
  # to the next key immediately instead of queueing up behind this one.
  defp claim_prekey(device_id) do
    query =
      from p in OneTimePrekey,
        where: p.device_id == ^device_id and is_nil(p.claimed_at),
        order_by: p.key_id,
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"

    case Repo.one(query) do
      nil ->
        nil

      prekey ->
        prekey |> Changeset.change(claimed_at: DateTime.utc_now()) |> Repo.update!()
        %{key_id: prekey.key_id, public_key: prekey.public_key}
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
