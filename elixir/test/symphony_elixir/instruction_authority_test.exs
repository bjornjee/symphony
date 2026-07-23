defmodule SymphonyElixir.InstructionAuthorityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.InstructionAuthority

  test "hashes ordered bounded instruction contents and rejects drift" do
    root = Path.join(System.tmp_dir!(), "instruction-authority-#{System.unique_integer([:positive])}")
    global = Path.join(root, "global.md")
    repository = Path.join(root, "AGENTS.md")
    File.mkdir_p!(root)
    File.write!(global, "global doctrine\n")
    File.write!(repository, "repository doctrine\n")

    sources = [%{"path" => global}, %{"path" => repository}]
    assert {:ok, authority} = InstructionAuthority.capture(sources)
    assert authority.paths == [global, repository]
    assert byte_size(authority.digest) == 64
    assert :ok = InstructionAuthority.revalidate(authority)

    File.write!(repository, "changed doctrine\n")
    assert {:error, :instruction_drift} = InstructionAuthority.revalidate(authority)
  end

  test "accepts path strings returned by current Codex app-server" do
    root = Path.join(System.tmp_dir!(), "instruction-authority-string-#{System.unique_integer([:positive])}")
    instruction = Path.join(root, "AGENTS.md")
    File.mkdir_p!(root)
    File.write!(instruction, "global doctrine\n")

    assert {:ok, authority} = InstructionAuthority.capture([instruction])
    assert authority.paths == [instruction]
    assert :ok = InstructionAuthority.revalidate(authority)
  end

  test "rejects missing, duplicate, and excessive instruction sources" do
    assert {:error, {:instruction_source_missing, "/missing"}} =
             InstructionAuthority.capture([%{"path" => "/missing"}])

    assert {:error, :duplicate_instruction_source} =
             InstructionAuthority.capture([%{"path" => "/missing"}, %{"path" => "/missing"}])

    sources = for index <- 1..33, do: %{"path" => "/missing/#{index}"}
    assert {:error, :too_many_instruction_sources} = InstructionAuthority.capture(sources)
  end
end
