defmodule SymphonyElixir.ExecutionLedgerTest do
  use ExUnit.Case

  alias SymphonyElixir.ExecutionLedger

  setup do
    root = Path.join(System.tmp_dir!(), "execution-ledger-#{System.os_time(:nanosecond)}")
    Application.put_env(:symphony_elixir, :execution_state_root, root)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :execution_state_root)
      File.rm_rf(root)
    end)

    key = ExecutionLedger.key("git@github.com:acme/repo.git", "issue-1", String.duplicate("a", 64))
    %{key: key, root: root}
  end

  test "persists immutable receipts outside the agent workspace", %{key: key, root: root} do
    receipt = %{"proof_id" => "final", "passed" => true}
    assert {:ok, persisted} = ExecutionLedger.create(key, "proof", "final-1", receipt)
    assert persisted["receipt_digest"]
    assert {:ok, ^persisted} = ExecutionLedger.read(key, "proof", "final-1")
    assert :exists = ExecutionLedger.create(key, "proof", "final-1", receipt)
    assert {:ok, [^persisted]} = ExecutionLedger.list(key, "proof")
    assert Path.expand(ExecutionLedger.path(key, "proof", "final-1")) |> String.starts_with?(Path.expand(root))
  end

  test "rejects invalid receipt path components", %{key: key} do
    assert {:error, :invalid_ledger_component} = ExecutionLedger.create(key, "../proof", "one", %{})
    assert {:error, :invalid_ledger_component} = ExecutionLedger.read(key, "proof", "../one")
  end

  test "rejects oversized and corrupted receipts", %{key: key} do
    assert {:error, :receipt_too_large} =
             ExecutionLedger.create(key, "proof", "huge", %{
               "output" => String.duplicate("x", 1_048_576)
             })

    path = ExecutionLedger.path(key, "proof", "corrupt")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{}")
    assert {:error, :invalid_receipt} = ExecutionLedger.read(key, "proof", "corrupt")

    File.write!(ExecutionLedger.path(key, "proof", "oversized"), String.duplicate("x", 1_048_577))
    assert {:error, :receipt_too_large} = ExecutionLedger.read(key, "proof", "oversized")
  end

  test "bounds receipt listings and rejects foreign filenames", %{key: key} do
    directory = Path.dirname(ExecutionLedger.path(key, "proof", "one"))
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "foreign"), "x")
    assert {:error, :invalid_receipt_filename} = ExecutionLedger.list(key, "proof")

    File.rm!(Path.join(directory, "foreign"))

    for index <- 1..257 do
      File.write!(Path.join(directory, "#{index}.json"), "{}")
    end

    assert {:error, :too_many_receipts} = ExecutionLedger.list(key, "proof")
  end
end
