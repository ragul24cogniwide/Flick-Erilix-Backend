defmodule ChatServer.LogRedaction do
  @moduledoc """
  Keeps secrets out of crash reports.

  When a GenServer such as a channel crashes, OTP logs its last message, its state,
  and the arguments in the stacktrace. For a channel these hold ciphertext, phone
  numbers, and tokens, so this filter blanks them while keeping the error and location.
  """

  def install do
    :logger.add_primary_filter(__MODULE__, {&__MODULE__.filter/2, []})
  end

  def filter(%{msg: {:report, %{label: {:gen_server, :terminate}} = report}} = event, _extra) do
    redacted = %{
      report
      | last_message: :redacted,
        state: :redacted,
        reason: redact_reason(report.reason)
    }

    event
    |> put_in([:msg], {:report, redacted})
    |> update_in([:meta], &Map.delete(&1, :crash_reason))
  end

  def filter(_event, _extra), do: :ignore

  defp redact_reason({reason, stack}) when is_list(stack) do
    {redact_exception(reason), Enum.map(stack, &redact_frame/1)}
  end

  defp redact_reason(reason), do: redact_exception(reason)

  # An exception's fields can quote the data that caused it, so only its type is kept.
  defp redact_exception(%{__exception__: true, __struct__: type}), do: type
  defp redact_exception(reason) when is_atom(reason), do: reason
  defp redact_exception(_reason), do: :redacted

  defp redact_frame({module, function, args, location}) when is_list(args) do
    {module, function, length(args), location}
  end

  defp redact_frame(frame), do: frame
end
