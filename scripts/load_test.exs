# Opens real WebSocket connections and exchanges messages between them.
#
#   scripts/run_load_test.sh --sockets 1000 --messages 5 --interval 1000
#
# The client and server share one BEAM, so this measures the whole system on one
# machine, and the client's own work counts against the server's results. Sign-in
# skips SMS by calling the context directly. Rate limits are lifted for the run,
# since every client shares one IP.

defmodule LoadTest.Client do
  @moduledoc "A minimal Phoenix Channels client over a raw TCP WebSocket."

  use GenServer

  def start(args), do: GenServer.start(__MODULE__, args)
  def connect_and_join(pid), do: GenServer.call(pid, :connect_and_join, 120_000)

  def send_message(pid, conversation_id),
    do: GenServer.cast(pid, {:send_message, conversation_id})

  @impl true
  def init(args) do
    {:ok, Map.merge(args, %{socket: nil, buffer: <<>>, ref: 1, sends: %{}, join_from: nil})}
  end

  @impl true
  def handle_call(:connect_and_join, from, state) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", state.port, [:binary, active: false, nodelay: true], 30_000)

    key = Base.encode64(:crypto.strong_rand_bytes(16))
    token = URI.encode_www_form(state.session.access_token)

    :ok =
      :gen_tcp.send(socket, [
        "GET /socket/websocket?vsn=2.0.0&token=#{token} HTTP/1.1\r\n",
        "Host: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
        "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
      ])

    {:ok, rest} = read_handshake(socket, <<>>)
    :inet.setopts(socket, active: :once)
    :timer.send_interval(30_000, :heartbeat)

    state = %{state | socket: socket, join_from: from}
    send_frame(state, ["1", "1", "user:#{state.session.user.id}", "phx_join", %{}])

    {:noreply, handle_data(rest, %{state | ref: 2})}
  end

  @impl true
  def handle_cast({:send_message, conversation_id}, state) do
    ref = Integer.to_string(state.ref)
    sent_at = System.monotonic_time(:microsecond)

    payload = %{
      conversation_id: conversation_id,
      client_msg_id: "#{state.session.device.id}-#{ref}",
      ciphertext: Base.encode64(<<sent_at::signed-64, state.padding::binary>>),
      kind: "text"
    }

    send_frame(state, ["1", ref, "user:#{state.session.user.id}", "msg:send", payload])

    {:noreply, %{state | ref: state.ref + 1, sends: Map.put(state.sends, ref, sent_at)}}
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) do
    :inet.setopts(socket, active: :once)
    {:noreply, handle_data(data, state)}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    :ets.update_counter(state.stats, :disconnects, 1)
    {:stop, :normal, state}
  end

  def handle_info(:heartbeat, state) do
    send_frame(state, [nil, "hb", "phoenix", "heartbeat", %{}])
    {:noreply, state}
  end

  defp read_handshake(socket, buffer) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 30_000)
    buffer = buffer <> data

    case :binary.split(buffer, "\r\n\r\n") do
      ["HTTP/1.1 101" <> _headers, rest] -> {:ok, rest}
      [_incomplete] -> read_handshake(socket, buffer)
    end
  end

  defp handle_data(data, state) do
    {frames, buffer} = parse_frames(state.buffer <> data, [])
    Enum.reduce(frames, %{state | buffer: buffer}, &handle_frame/2)
  end

  defp parse_frames(
         <<_::4, op::4, 0::1, 126::7, len::16, body::binary-size(len), rest::binary>>,
         acc
       ),
       do: parse_frames(rest, [{op, body} | acc])

  defp parse_frames(
         <<_::4, op::4, 0::1, 127::7, len::64, body::binary-size(len), rest::binary>>,
         acc
       ),
       do: parse_frames(rest, [{op, body} | acc])

  defp parse_frames(<<_::4, op::4, 0::1, len::7, body::binary-size(len), rest::binary>>, acc)
       when len < 126,
       do: parse_frames(rest, [{op, body} | acc])

  defp parse_frames(rest, acc), do: {Enum.reverse(acc), rest}

  defp handle_frame({1, body}, state), do: handle_event(Jason.decode!(body), state)
  defp handle_frame(_control_frame, state), do: state

  defp handle_event([_join, "1", _topic, "phx_reply", %{"status" => status}], state) do
    GenServer.reply(state.join_from, status)
    state
  end

  defp handle_event([_join, ref, _topic, "phx_reply", %{"status" => status}], state) do
    case Map.pop(state.sends, ref) do
      {nil, _sends} ->
        state

      {sent_at, sends} ->
        if status == "ok" do
          :ets.insert(state.acks, {make_ref(), System.monotonic_time(:microsecond) - sent_at})
        else
          :ets.update_counter(state.stats, :send_errors, 1)
        end

        %{state | sends: sends}
    end
  end

  defp handle_event([_join, _ref, topic, "msg:new", payload], state) do
    now = System.monotonic_time(:microsecond)
    <<sent_at::signed-64, _padding::binary>> = Base.decode64!(payload["ciphertext"])

    if :ets.insert_new(state.seen, {{state.session.device.id, payload["message_id"]}}) do
      :ets.insert(state.deliveries, {make_ref(), now - sent_at})
    else
      :ets.update_counter(state.stats, :duplicates, 1)
    end

    ack = %{message_ids: [payload["message_id"]]}
    send_frame(state, ["1", "ack-#{payload["message_id"]}", topic, "msg:ack_delivered", ack])
    state
  end

  defp handle_event(_other, state), do: state

  # RFC 6455 requires clients to XOR-mask frames. This is framing, not encryption.
  defp send_frame(state, message) do
    body = Jason.encode!(message)
    size = byte_size(body)
    mask = :crypto.strong_rand_bytes(4)
    keystream = binary_part(:binary.copy(mask, div(size, 4) + 1), 0, size)

    length_bytes =
      cond do
        size < 126 -> <<1::1, size::7>>
        size < 65_536 -> <<1::1, 126::7, size::16>>
        true -> <<1::1, 127::7, size::64>>
      end

    :gen_tcp.send(state.socket, [
      <<1::1, 0::3, 1::4>>,
      length_bytes,
      mask,
      :crypto.exor(body, keystream)
    ])
  end
end

defmodule LoadTest do
  import Ecto.Query

  alias ChatServer.Accounts
  alias ChatServer.Accounts.{Device, User}
  alias ChatServer.Conversations
  alias ChatServer.Conversations.Conversation
  alias ChatServer.Messaging.{Delivery, Message}
  alias ChatServer.Repo

  @phone_prefix "+1999"

  def run(argv) do
    # parse! raises on bad arguments, so a typo cannot quietly run the defaults.
    {opts, _rest} =
      OptionParser.parse!(argv,
        strict: [sockets: :integer, messages: :integer, interval: :integer, size: :integer]
      )

    sockets = (opts[:sockets] || 1000) |> div(2) |> Kernel.*(2)
    messages = opts[:messages] || 5
    interval = opts[:interval] || 1000
    size = opts[:size] || 256

    limits = Application.fetch_env!(:chat_server, :rate_limits)
    lifted = Keyword.new(limits, fn {scope, _limit} -> {scope, {1_000_000_000, 60}} end)
    Application.put_env(:chat_server, :rate_limits, lifted)

    delete_test_data()

    IO.puts("Creating #{sockets} signed-in devices and #{div(sockets, 2)} conversations...")
    sessions = create_sessions(sockets)
    conversations = create_conversations(sessions)

    tables = %{
      acks: :ets.new(:acks, [:public, :duplicate_bag, write_concurrency: true]),
      deliveries: :ets.new(:deliveries, [:public, :duplicate_bag, write_concurrency: true]),
      seen: :ets.new(:seen, [:public, :set, write_concurrency: true]),
      stats: :ets.new(:stats, [:public, :set, write_concurrency: true])
    }

    :ets.insert(tables.stats, [{:disconnects, 0}, {:send_errors, 0}, {:duplicates, 0}])

    memory_before = :erlang.memory(:total)

    IO.puts("Connecting #{sockets} sockets...")
    {connect_us, clients} = :timer.tc(fn -> connect_clients(sessions, tables, size) end)
    joined = Enum.count(clients, fn {_client, status} -> status == "ok" end)
    Process.sleep(2_000)
    memory_per_socket = div(:erlang.memory(:total) - memory_before, max(joined, 1))

    expected = length(clients) * messages
    IO.puts("Sending #{expected} messages: #{messages} per socket, one every #{interval} ms...")

    {total_us, _} =
      :timer.tc(fn ->
        send_all(clients, conversations, messages, interval)
        wait_for(tables, expected, 180_000)
      end)

    Process.sleep(2_000)

    report(%{
      sockets: sockets,
      joined: joined,
      connect_seconds: connect_us / 1_000_000,
      memory_per_socket: memory_per_socket,
      expected: expected,
      send_seconds: total_us / 1_000_000,
      offered_rate: round(sockets * 1000 / interval),
      tables: tables,
      schedulers: System.schedulers_online(),
      size: size
    })

    delete_test_data(Enum.map(conversations, & &1.id))
  end

  defp create_sessions(count) do
    changeset = Device.changeset(%Device{}, %{platform: :android})

    1..count
    |> Task.async_stream(
      fn i ->
        phone = @phone_prefix <> String.pad_leading(Integer.to_string(i), 8, "0")
        {:ok, session} = Accounts.start_session(phone, changeset)
        session
      end,
      max_concurrency: 10,
      timeout: 60_000
    )
    |> Enum.map(fn {:ok, session} -> session end)
  end

  defp create_conversations(sessions) do
    sessions
    |> Enum.chunk_every(2)
    |> Enum.map(fn [first, second] ->
      {:ok, conversation, _status} =
        Conversations.create_conversation(first.user, %{
          "kind" => "direct",
          "user_id" => second.user.id
        })

      conversation
    end)
  end

  defp connect_clients(sessions, tables, size) do
    port = ChatServerWeb.Endpoint.config(:http)[:port]
    padding = :binary.copy(<<0>>, max(size - 8, 0))

    sessions
    |> Task.async_stream(
      fn session ->
        {:ok, pid} =
          LoadTest.Client.start(
            Map.merge(tables, %{session: session, port: port, padding: padding})
          )

        {pid, LoadTest.Client.connect_and_join(pid)}
      end,
      max_concurrency: 50,
      timeout: 180_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp send_all(clients, conversations, messages, interval) do
    clients
    |> Enum.chunk_every(2)
    |> Enum.zip(conversations)
    |> Enum.flat_map(fn {pair, conversation} ->
      Enum.map(pair, fn {client, _status} ->
        Task.async(fn ->
          Process.sleep(:rand.uniform(interval))

          for _ <- 1..messages do
            LoadTest.Client.send_message(client, conversation.id)
            Process.sleep(interval)
          end
        end)
      end)
    end)
    |> Task.await_many(:infinity)
  end

  defp wait_for(tables, expected, timeout) when timeout > 0 do
    if :ets.info(tables.deliveries, :size) < expected do
      Process.sleep(100)
      wait_for(tables, expected, timeout - 100)
    end
  end

  defp wait_for(_tables, _expected, _timeout), do: :ok

  defp report(run) do
    deliveries = sorted_ms(run.tables.deliveries)
    acks = sorted_ms(run.tables.acks)
    [{_, disconnects}] = :ets.lookup(run.tables.stats, :disconnects)
    [{_, send_errors}] = :ets.lookup(run.tables.stats, :send_errors)
    [{_, duplicates}] = :ets.lookup(run.tables.stats, :duplicates)

    pending =
      Repo.aggregate(from(d in Delivery, where: is_nil(d.delivered_at)), :count)

    held = Repo.aggregate(from(m in Message, where: not is_nil(m.ciphertext)), :count)

    IO.puts("""

    | Measure | Result |
    | --- | --- |
    | Schedulers (CPU threads) | #{run.schedulers} |
    | Sockets joined | #{run.joined} of #{run.sockets} |
    | Time to connect and join all | #{round1(run.connect_seconds)} s |
    | Memory per socket | #{div(run.memory_per_socket, 1024)} KB |
    | Messages sent (#{run.size}-byte payload) | #{run.expected} |
    | Rate attempted | #{run.offered_rate} messages/s |
    | Rate achieved, first send to last delivery | #{round(length(deliveries) / max(run.send_seconds, 0.001))} messages/s |
    | Messages delivered | #{length(deliveries)} of #{run.expected} |
    | Send ack latency p50 / p95 / p99 | #{percentiles(acks)} |
    | End-to-end delivery latency p50 / p95 / p99 | #{percentiles(deliveries)} |
    | Send errors | #{send_errors} |
    | Duplicate deliveries | #{duplicates} |
    | Unexpected disconnects | #{disconnects} |
    | Deliveries still pending after acks | #{pending} |
    | Ciphertexts still held after acks | #{held} |
    """)
  end

  defp sorted_ms(table) do
    table |> :ets.tab2list() |> Enum.map(fn {_ref, us} -> us / 1000 end) |> Enum.sort()
  end

  defp percentiles([]), do: "n/a"

  defp percentiles(values) do
    [0.5, 0.95, 0.99]
    |> Enum.map_join(" / ", fn p ->
      "#{round1(Enum.at(values, min(round(p * length(values)), length(values) - 1)))} ms"
    end)
  end

  defp round1(number), do: Float.round(number * 1.0, 1)

  defp delete_test_data(conversation_ids \\ []) do
    Repo.delete_all(from c in Conversation, where: c.id in ^conversation_ids)
    Repo.delete_all(from u in User, where: like(u.phone, ^"#{@phone_prefix}%"))
  end
end

Logger.configure(level: :warning)
LoadTest.run(System.argv())
