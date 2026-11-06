defmodule ChatServerWeb.KeyController do
  use ChatServerWeb, :controller

  alias ChatServer.Keys

  action_fallback ChatServerWeb.FallbackController

  # Each fetch uses up one of the target's one-time prekeys, so limit how fast.
  plug ChatServerWeb.Plugs.RateLimit, :keys_fetch_user when action == :show

  def upload(conn, params) do
    with {:ok, available} <- Keys.upload_keys(conn.assigns.current_device, params) do
      json(conn, %{one_time_prekeys_available: available})
    end
  end

  def show(conn, %{"user_id" => user_id}) do
    with {:ok, bundles} <- Keys.fetch_bundles(user_id) do
      json(conn, %{user_id: user_id, devices: Enum.map(bundles, &bundle_json/1)})
    end
  end

  defp bundle_json(bundle) do
    %{
      device_id: bundle.device_id,
      identity_public_key: Base.encode64(bundle.identity_public_key),
      signed_prekey: Base.encode64(bundle.signed_prekey),
      signed_prekey_signature: Base.encode64(bundle.signed_prekey_signature),
      one_time_prekey: prekey_json(bundle.one_time_prekey)
    }
  end

  defp prekey_json(nil), do: nil

  defp prekey_json(prekey) do
    %{key_id: prekey.key_id, public_key: Base.encode64(prekey.public_key)}
  end
end
