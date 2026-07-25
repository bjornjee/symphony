defmodule SymphonyElixir.ServiceCommandsTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../../bin/symphony-service", __DIR__)

  test "status reports stopped when the observability API is unavailable" do
    root = temp_dir!("status")
    fake_bin = Path.join(root, "bin")
    File.mkdir_p!(fake_bin)
    write_executable!(Path.join(fake_bin, "curl"), "#!/bin/sh\nexit 7\n")

    {output, status} =
      System.cmd("sh", [@script, "status"],
        env: [
          {"PATH", "#{fake_bin}:#{System.get_env("PATH")}"},
          {"SYMPHONY_SERVICE_DIR", Path.join(root, "state")}
        ],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "Symphony stopped"
  end

  test "down refuses to stop an externally managed instance" do
    root = temp_dir!("external")
    fake_bin = Path.join(root, "bin")
    File.mkdir_p!(fake_bin)

    write_executable!(
      Path.join(fake_bin, "curl"),
      "#!/bin/sh\nprintf '%s\\n' '{\"counts\":{\"running\":0,\"retrying\":0,\"blocked\":0}}'\n"
    )

    {output, status} =
      System.cmd("sh", [@script, "down"],
        env: [
          {"PATH", "#{fake_bin}:#{System.get_env("PATH")}"},
          {"SYMPHONY_SERVICE_DIR", Path.join(root, "state")}
        ],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "running outside service management"
  end

  test "up is worktree-safe, idempotent, observable, and stoppable" do
    root = temp_dir!("lifecycle")
    primary = Path.join(root, "primary")
    worktree = Path.join(root, "worktree")
    fake_bin = Path.join(root, "fake-bin")
    state_dir = Path.join(root, "state")
    ready_path = Path.join(root, "ready")
    token_path = Path.join(root, "token")
    ca_bundle = Path.join(root, "cert.pem")

    File.mkdir_p!(primary)
    File.mkdir_p!(fake_bin)
    File.write!(ca_bundle, "test certificate fixture")

    git!(primary, ["init", "-b", "main"])
    git!(primary, ["config", "user.email", "test@example.com"])
    git!(primary, ["config", "user.name", "Test User"])
    File.write!(Path.join(primary, "README.md"), "fixture\n")
    git!(primary, ["add", "README.md"])
    git!(primary, ["commit", "-m", "fixture"])
    git!(primary, ["worktree", "add", "-b", "feature/service-test", worktree])

    File.write!(Path.join(primary, ".env"), "LINEAR_API_KEY=worktree-token\n")
    File.mkdir_p!(Path.join(worktree, "bin"))
    File.mkdir_p!(Path.join(worktree, "elixir/bin"))
    File.mkdir_p!(Path.join(worktree, "workflows/symphony"))
    File.cp!(@script, Path.join(worktree, "bin/symphony-service"))
    write_executable!(Path.join(worktree, "elixir/bin/symphony"), "#!/bin/sh\n")
    File.write!(Path.join(worktree, "workflows/symphony/workflow.md"), "fixture\n")

    write_executable!(
      Path.join(fake_bin, "mise"),
      """
      #!/bin/sh
      printf '%s' "$LINEAR_API_KEY" > "$FAKE_TOKEN_PATH"
      : > "$FAKE_READY_PATH"
      exec sleep 30
      """
    )

    write_executable!(
      Path.join(fake_bin, "curl"),
      """
      #!/bin/sh
      test -f "$FAKE_READY_PATH" || exit 7
      printf '%s\n' '{"counts":{"running":1,"retrying":2,"blocked":3}}'
      """
    )

    env = [
      {"PATH", "#{fake_bin}:#{System.get_env("PATH")}"},
      {"SYMPHONY_SERVICE_DIR", state_dir},
      {"CA_BUNDLE", ca_bundle},
      {"PORT", "4400"},
      {"FAKE_READY_PATH", ready_path},
      {"FAKE_TOKEN_PATH", token_path}
    ]

    on_exit(fn ->
      System.cmd("sh", [Path.join(worktree, "bin/symphony-service"), "down"],
        env: env,
        stderr_to_stdout: true
      )
    end)

    {up_output, 0} =
      System.cmd("sh", [Path.join(worktree, "bin/symphony-service"), "up"],
        env: env,
        stderr_to_stdout: true
      )

    assert up_output =~ "Symphony running"
    assert up_output =~ "Dashboard: http://127.0.0.1:4400/"
    assert File.read!(token_path) == "worktree-token"
    first_pid = File.read!(Path.join(state_dir, "pid"))

    {second_up_output, 0} =
      System.cmd("sh", [Path.join(worktree, "bin/symphony-service"), "up"],
        env: env,
        stderr_to_stdout: true
      )

    assert second_up_output =~ "Symphony already running"
    assert File.read!(Path.join(state_dir, "pid")) == first_pid

    {status_output, 0} =
      System.cmd("sh", [Path.join(worktree, "bin/symphony-service"), "status"],
        env: env,
        stderr_to_stdout: true
      )

    assert status_output =~ "Agents: 1 running, 2 retrying, 3 blocked"

    {down_output, 0} =
      System.cmd("sh", [Path.join(worktree, "bin/symphony-service"), "down"],
        env: env,
        stderr_to_stdout: true
      )

    assert down_output =~ "Symphony stopped"
    refute File.exists?(Path.join(state_dir, "pid"))
  end

  defp git!(directory, args) do
    {_output, 0} = System.cmd("git", args, cd: directory, stderr_to_stdout: true)
  end

  defp temp_dir!(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-service-#{name}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
