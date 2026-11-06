defmodule ChatServerWeb.FallbackController do
  @moduledoc "Turns context errors into JSON responses."

  use ChatServerWeb, :controller

  @statuses %{
    forbidden: :forbidden,
    invalid_code: :unauthorized,
    code_expired: :unauthorized,
    invalid_refresh_token: :unauthorized,
    too_many_attempts: :too_many_requests,
    not_found: :not_found,
    invalid_phone: :unprocessable_entity,
    invalid_hashes: :unprocessable_entity,
    invalid_prekeys: :unprocessable_entity,
    no_keys: :unprocessable_entity,
    invalid_cursor: :unprocessable_entity,
    user_not_found: :unprocessable_entity,
    not_a_group: :unprocessable_entity,
    last_admin: :unprocessable_entity,
    group_full: :unprocessable_entity,
    phone_country_not_supported: :unprocessable_entity,
    sms_provider_not_configured: :service_unavailable,
    sms_provider_not_ready: :service_unavailable,
    sms_delivery_failed: :bad_gateway
  }

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "validation_failed", details: errors_on(changeset)})
  end

  def call(conn, {:error, reason}) when is_map_key(@statuses, reason) do
    conn |> put_status(@statuses[reason]) |> json(%{error: reason})
  end

  def call(conn, {:error, _reason}) do
    conn |> put_status(:bad_gateway) |> json(%{error: "upstream_failure"})
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _match, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
