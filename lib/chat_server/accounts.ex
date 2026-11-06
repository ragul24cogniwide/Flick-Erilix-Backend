defmodule ChatServer.Accounts do
  @moduledoc "Sign-in, sessions, and profiles."

  import Ecto.Query

  alias ChatServer.Accounts.{Device, OtpCode, RefreshToken, User}
  alias ChatServer.{Repo, SmsProvider}
  alias ChatServerWeb.Endpoint
  alias Ecto.Multi

  @otp_ttl_seconds 5 * 60
  @otp_max_attempts 5
  @access_token_ttl_seconds 15 * 60
  @refresh_token_ttl_seconds 30 * 24 * 60 * 60
  @access_token_salt "access token"

  def access_token_ttl_seconds, do: @access_token_ttl_seconds

  ## One-time codes

  @doc "Creates a code for the phone, replacing any earlier one, and sends it by SMS."
  def request_otp(phone) do
    if User.valid_phone?(phone) do
      code = generate_code()
      now = now()

      {:ok, _result} =
        Multi.new()
        |> Multi.update_all(:replace_earlier, active_otps(phone), set: [consumed_at: now])
        |> Multi.insert(:otp, %OtpCode{
          phone: phone,
          code_hash: hash_code(phone, code),
          expires_at: DateTime.add(now, @otp_ttl_seconds)
        })
        |> Repo.transaction()

      SmsProvider.send_otp(phone, code)
    else
      {:error, :invalid_phone}
    end
  end

  @doc """
  Checks a code and, when it matches, signs the phone in on a new device.

  A wrong guess is committed even though the call returns an error, so the attempt
  limit cannot be bypassed. The row lock stops parallel guesses sharing one count.
  """
  def verify_otp(phone, code, device_attrs) do
    device_changeset = Device.changeset(%Device{}, device_attrs)

    if device_changeset.valid? do
      {:ok, result} = Repo.transaction(fn -> redeem_otp(phone, code, device_changeset) end)
      result
    else
      {:error, device_changeset}
    end
  end

  defp redeem_otp(phone, code, device_changeset) do
    otp = phone |> active_otps() |> latest_first() |> lock("FOR UPDATE") |> Repo.one()

    with :ok <- check_otp(otp, phone, code),
         {:ok, _consumed} <- consume(otp) do
      start_session(phone, device_changeset)
    end
  end

  defp active_otps(phone) do
    from o in OtpCode, where: o.phone == ^phone and is_nil(o.consumed_at)
  end

  defp latest_first(query), do: from(o in query, order_by: [desc: o.inserted_at], limit: 1)

  defp check_otp(nil, _phone, _code), do: {:error, :invalid_code}

  defp check_otp(%OtpCode{} = otp, phone, code) do
    cond do
      DateTime.compare(otp.expires_at, now()) != :gt ->
        {:error, :code_expired}

      otp.attempts >= @otp_max_attempts ->
        {:error, :too_many_attempts}

      is_binary(code) and Plug.Crypto.secure_compare(hash_code(phone, code), otp.code_hash) ->
        :ok

      true ->
        {1, _rows} =
          Repo.update_all(from(o in OtpCode, where: o.id == ^otp.id), inc: [attempts: 1])

        {:error, :invalid_code}
    end
  end

  defp consume(otp) do
    otp |> Ecto.Changeset.change(consumed_at: now()) |> Repo.update()
  end

  defp generate_code do
    <<number::unsigned-32>> = :crypto.strong_rand_bytes(4)
    number |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  # A six-digit code is trivially reversible from a plain hash, so it is keyed with
  # the server secret. Including the phone ties a code's hash to that phone.
  defp hash_code(phone, code) do
    :crypto.mac(:hmac, :sha256, Endpoint.config(:secret_key_base), [phone, ":", code])
  end

  ## Sessions

  @doc """
  Signs a phone in on a new device, creating the user on first sign-in.

  The caller must already have proved ownership of the phone.
  """
  def start_session(phone, %Ecto.Changeset{} = device_changeset) do
    Multi.new()
    |> Multi.insert(:user, User.registration_changeset(%User{}, %{phone: phone}),
      on_conflict: {:replace, [:updated_at]},
      conflict_target: :phone,
      returning: true
    )
    |> Multi.insert(:device, fn %{user: user} ->
      device_changeset
      |> Ecto.Changeset.put_change(:user_id, user.id)
      |> Ecto.Changeset.put_change(:last_seen_at, now())
    end)
    |> put_refresh_token()
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user, device: device, refresh_token: refresh_token}} ->
        {:ok, session(user, device, refresh_token)}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Exchanges a refresh token for a new access and refresh token.

  Presenting a token that was already rotated means it leaked or was replayed, so
  that revokes the device's whole session.
  """
  def refresh_session(raw_token) when is_binary(raw_token) do
    hash = hash_refresh_token(raw_token)

    {:ok, result} =
      Repo.transaction(fn ->
        from(r in RefreshToken, where: r.token_hash == ^hash, lock: "FOR UPDATE")
        |> Repo.one()
        |> rotate_refresh_token()
      end)

    result
  end

  def refresh_session(_raw_token), do: {:error, :invalid_refresh_token}

  defp rotate_refresh_token(nil), do: {:error, :invalid_refresh_token}

  defp rotate_refresh_token(%RefreshToken{revoked_at: %DateTime{}} = token) do
    Repo.update_all(active_refresh_tokens(token.device_id), set: [revoked_at: now()])
    {:error, :invalid_refresh_token}
  end

  defp rotate_refresh_token(%RefreshToken{} = token) do
    if DateTime.compare(token.expires_at, now()) == :gt do
      device = Device |> Repo.get!(token.device_id) |> Repo.preload(:user)

      {:ok, %{refresh_token: refresh_token}} =
        Multi.new()
        |> Multi.update(:revoke, Ecto.Changeset.change(token, revoked_at: now()))
        |> Multi.put(:device, device)
        |> put_refresh_token()
        |> Repo.transaction()

      {:ok, session(device.user, device, refresh_token)}
    else
      {:error, :invalid_refresh_token}
    end
  end

  @doc "Ends a device's session: revokes its tokens and closes its open sockets."
  def logout(%Device{} = device) do
    Repo.update_all(active_refresh_tokens(device.id), set: [revoked_at: now()])
    Endpoint.broadcast(socket_id(device.id), "disconnect", %{})
    :ok
  end

  @doc "Topic used to force-close a device's sockets."
  def socket_id(device_id), do: "device_socket:#{device_id}"

  @doc """
  Resolves an access token to `{user, device}`.

  The session check means logging out takes effect immediately rather than when
  the 15-minute token expires.
  """
  def authenticate(token) when is_binary(token) do
    with {:ok, %{user_id: user_id, device_id: device_id}} <-
           Phoenix.Token.verify(Endpoint, @access_token_salt, token,
             max_age: @access_token_ttl_seconds
           ),
         {%User{} = user, %Device{} = device} <- fetch_active_device(user_id, device_id) do
      {:ok, user, device}
    else
      _invalid -> {:error, :unauthorized}
    end
  end

  def authenticate(_token), do: {:error, :unauthorized}

  defp fetch_active_device(user_id, device_id) do
    from(d in Device,
      as: :device,
      join: u in assoc(d, :user),
      where: d.id == ^device_id and u.id == ^user_id,
      where: exists(active_session_query()),
      select: {u, d}
    )
    |> Repo.one()
  end

  @doc "A subquery matching an active session of the device bound as `:device`."
  def active_session_query do
    now = now()

    from r in RefreshToken,
      where: r.device_id == parent_as(:device).id,
      where: is_nil(r.revoked_at) and r.expires_at > ^now,
      select: 1
  end

  defp active_refresh_tokens(device_id) do
    from r in RefreshToken, where: r.device_id == ^device_id and is_nil(r.revoked_at)
  end

  defp put_refresh_token(multi) do
    raw_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    multi
    |> Multi.insert(:refresh_token_row, fn %{device: device} ->
      %RefreshToken{
        device_id: device.id,
        token_hash: hash_refresh_token(raw_token),
        expires_at: DateTime.add(now(), @refresh_token_ttl_seconds)
      }
    end)
    |> Multi.put(:refresh_token, raw_token)
  end

  defp session(user, device, refresh_token) do
    %{
      user: user,
      device: device,
      refresh_token: refresh_token,
      access_token:
        Phoenix.Token.sign(Endpoint, @access_token_salt, %{user_id: user.id, device_id: device.id})
    }
  end

  defp hash_refresh_token(raw_token), do: :crypto.hash(:sha256, raw_token)

  ## Profiles and devices

  def update_profile(%User{} = user, attrs) do
    user |> User.profile_changeset(attrs) |> Repo.update()
  end

  def touch_device(%Device{} = device) do
    Repo.update_all(from(d in Device, where: d.id == ^device.id), set: [last_seen_at: now()])
    :ok
  end

  def update_push_token(%Device{} = device, attrs) do
    device |> Device.push_token_changeset(attrs) |> Repo.update()
  end

  @max_contact_hashes 1000

  @doc "Finds registered users by the SHA-256 hex hash of their phone number."
  def match_contacts(hashes) when is_list(hashes) and length(hashes) <= @max_contact_hashes do
    if Enum.all?(hashes, &is_binary/1) do
      {:ok, Repo.all(from u in User, where: u.phone_hash in ^hashes)}
    else
      {:error, :invalid_hashes}
    end
  end

  def match_contacts(_hashes), do: {:error, :invalid_hashes}

  ## Maintenance

  @doc "Deletes OTP codes and refresh tokens past their expiry."
  def delete_expired_credentials do
    now = now()
    {otps, _rows} = Repo.delete_all(from o in OtpCode, where: o.expires_at < ^now)
    {tokens, _rows} = Repo.delete_all(from r in RefreshToken, where: r.expires_at < ^now)
    %{otp_codes: otps, refresh_tokens: tokens}
  end

  defp now, do: DateTime.utc_now()
end
