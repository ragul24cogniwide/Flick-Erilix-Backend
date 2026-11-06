defmodule ChatServer.KeysConcurrencyTest do
  @moduledoc """
  Uses real database connections and real commits. The usual SQL sandbox runs everything
  on one connection and transaction, where row locks can never conflict, so it would
  pass this test even with a broken claim.
  """

  use ExUnit.Case, async: false

  import ChatServer.Fixtures
  import Ecto.Query

  alias ChatServer.Accounts.User
  alias ChatServer.Keys
  alias ChatServer.Keys.OneTimePrekey
  alias ChatServer.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @fetchers 16

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    session = session_fixture(keys: false)

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from u in User, where: u.id == ^session.user.id)
    end)

    %{session: session}
  end

  defp upload(session, prekey_count) do
    {:ok, ^prekey_count} =
      Keys.upload_keys(session.device, %{
        "identity_public_key" => Base.encode64("identity"),
        "signed_prekey" => Base.encode64("signed"),
        "signed_prekey_signature" => Base.encode64("signature"),
        "one_time_prekeys" =>
          for(
            id <- 1..prekey_count,
            do: %{"key_id" => id, "public_key" => Base.encode64("k#{id}")}
          )
      })
  end

  # Runs fetches at the same moment, each on its own connection.
  defp fetch_concurrently(session) do
    test_pid = self()

    tasks =
      for _ <- 1..@fetchers do
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)
          send(test_pid, {:ready, self()})

          receive do
            :go -> Keys.fetch_bundles(session.user.id)
          end
        end)
      end

    for task <- tasks do
      assert_receive {:ready, pid} when pid == task.pid, 5_000
    end

    for task <- tasks, do: send(task.pid, :go)

    tasks
    |> Task.await_many(15_000)
    |> Enum.map(fn {:ok, [bundle]} -> bundle.one_time_prekey end)
  end

  defp claimed_count(session) do
    Repo.aggregate(
      from(p in OneTimePrekey,
        where: p.device_id == ^session.device.id and not is_nil(p.claimed_at)
      ),
      :count
    )
  end

  test "concurrent fetches never receive the same prekey", %{session: session} do
    upload(session, @fetchers)

    prekeys = fetch_concurrently(session)

    assert Enum.all?(prekeys), "with enough keys for everyone, every fetch should get one"
    assert prekeys |> Enum.map(& &1.key_id) |> Enum.uniq() |> length() == @fetchers
    assert claimed_count(session) == @fetchers
  end

  test "when keys run out, each is still handed out exactly once", %{session: session} do
    upload(session, 4)

    prekeys = fetch_concurrently(session)
    claimed = Enum.reject(prekeys, &is_nil/1)

    assert length(claimed) == 4
    assert claimed |> Enum.map(& &1.key_id) |> Enum.uniq() |> length() == 4
    assert Enum.count(prekeys, &is_nil/1) == @fetchers - 4
    assert claimed_count(session) == 4
  end
end
