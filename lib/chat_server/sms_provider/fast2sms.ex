defmodule ChatServer.SmsProvider.Fast2Sms do
  @moduledoc """
  Sends sign-in codes through Fast2SMS's OTP route.

  Fast2SMS only reaches Indian mobile numbers, so other countries get an error. The
  account must complete website verification under "OTP Message" in the Fast2SMS panel
  first. Until then Fast2SMS answers with status 996, and sign-in returns 503.
  """

  @behaviour ChatServer.SmsProvider

  alias ChatServer.Http

  require Logger

  @indian_mobile ~r/^\+91([6-9][0-9]{9})$/
  @website_verification_needed 996
  @invalid_key 412

  @impl true
  def send_otp(phone, code) do
    case Regex.run(@indian_mobile, phone) do
      [_phone, national_number] -> deliver(national_number, code)
      nil -> {:error, :phone_country_not_supported}
    end
  end

  @doc "Returns the wallet balance in rupees. It sends nothing, so it is a safe way to test the key."
  def wallet_balance do
    with {:ok, 200, body} <- Http.request(:get, "#{base_url()}/dev/wallet", auth_header()),
         {:ok, %{"return" => true, "wallet" => wallet}} <- Jason.decode(body) do
      {:ok, wallet}
    else
      _failure -> {:error, :sms_delivery_failed}
    end
  end

  defp deliver(national_number, code) do
    body =
      Jason.encode!(%{route: "otp", variables_values: code, numbers: national_number})

    case Http.request(
           :post,
           "#{base_url()}/dev/bulkV2",
           auth_header(),
           {"application/json", body}
         ) do
      {:ok, status, response} -> handle_response(status, Jason.decode(response))
      {:error, :unreachable} -> report_failure("unreachable")
    end
  end

  defp handle_response(200, {:ok, %{"return" => true}}), do: :ok

  defp handle_response(_status, {:ok, %{"status_code" => @website_verification_needed}}) do
    Logger.error(
      "Fast2SMS refused the code: complete website verification under OTP Message in its panel"
    )

    {:error, :sms_provider_not_ready}
  end

  defp handle_response(_status, {:ok, %{"status_code" => @invalid_key}}) do
    Logger.error("Fast2SMS refused the code: FAST2SMS_API_KEY is invalid")
    {:error, :sms_provider_not_ready}
  end

  defp handle_response(_status, {:ok, %{"status_code" => status_code}}) do
    report_failure("status_code=#{inspect(status_code)}")
  end

  defp handle_response(status, _response), do: report_failure("http_status=#{status}")

  # Only codes are logged: Fast2SMS's message text could quote the phone number.
  defp report_failure(detail) do
    Logger.error("Fast2SMS could not send the code: #{detail}")
    {:error, :sms_delivery_failed}
  end

  defp auth_header do
    [{"authorization", Application.fetch_env!(:chat_server, :fast2sms_api_key)}]
  end

  defp base_url do
    Application.get_env(:chat_server, :fast2sms_base_url, "https://www.fast2sms.com")
  end
end
