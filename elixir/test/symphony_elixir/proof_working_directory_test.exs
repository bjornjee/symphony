defmodule SymphonyElixir.ProofWorkingDirectoryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProofWorkingDirectory

  test "accepts repository directories and rejects symlink escape" do
    root = Path.join(System.tmp_dir!(), "proof-directory-#{System.unique_integer([:positive])}")
    outside = Path.join(System.tmp_dir!(), "proof-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "subdir"))
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "escape"))

    assert {:ok, directory} = ProofWorkingDirectory.resolve(root, "subdir", nil)
    assert {:ok, expected} = SymphonyElixir.PathSafety.canonicalize(Path.join(root, "subdir"))
    assert directory == expected
    assert {:error, :proof_working_directory_escape} = ProofWorkingDirectory.resolve(root, "escape", nil)
  end
end
