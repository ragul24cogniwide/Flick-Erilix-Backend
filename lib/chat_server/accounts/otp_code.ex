defmodule ChatServer.Accounts.OtpCode do
  @moduledoc "A hashed one-time sign-in code. The plain code is never stored."

  use ChatServer.Schema

  schema "otp_codes" do
    field :phone, :string
    field :code_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :consumed_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end
end
