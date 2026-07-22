defmodule SymphonyElixir.ProofWorkingDirectory do
  @moduledoc "Resolves approved proof directories without permitting symlink or traversal escape."

  alias SymphonyElixir.{PathSafety, SSH}

  @spec resolve(Path.t(), Path.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def resolve(workspace, relative, nil) do
    with {:ok, root} <- PathSafety.canonicalize(workspace),
         {:ok, directory} <- PathSafety.canonicalize(Path.join(workspace, relative)),
         true <-
           (directory == root or String.starts_with?(directory, root <> "/")) ||
             {:error, :proof_working_directory_escape},
         true <- File.dir?(directory) || {:error, :proof_working_directory_missing} do
      {:ok, directory}
    end
  end

  def resolve(workspace, relative, worker_host) do
    path = Path.join(workspace, relative)

    command =
      "root=$(realpath #{shell_escape(workspace)}) && " <>
        "target=$(realpath #{shell_escape(path)}) && test -d \"$target\" && " <>
        "case \"$target/\" in \"$root/\"*) printf '%s' \"$target\" ;; *) exit 45 ;; esac"

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {directory, 0}} -> {:ok, String.trim(directory)}
      {:ok, {_output, 45}} -> {:error, :proof_working_directory_escape}
      {:ok, {output, status}} -> {:error, {:proof_working_directory_unavailable, status, output}}
      {:error, reason} -> {:error, {:proof_working_directory_unavailable, reason}}
    end
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
