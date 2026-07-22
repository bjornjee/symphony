defmodule SymphonyElixir.GitHubRepositoryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubRepository

  test "normalizes SSH repository origins" do
    assert {:ok, "acme/repo"} = GitHubRepository.from_origin("git@github.com:acme/repo.git")
  end

  test "normalizes HTTPS repository origins" do
    assert {:ok, "acme/repo"} = GitHubRepository.from_origin("https://github.com/acme/repo.git")
  end

  test "rejects unsupported repository origins" do
    assert {:error, :unsupported_repository_origin} =
             GitHubRepository.from_origin("https://example.com/acme/repo.git")
  end

  test "parses a canonical pull request URL" do
    assert {:ok, %{repository: "acme/repo", number: 42}} =
             GitHubRepository.pull_request_url("https://github.com/acme/repo/pull/42")
  end

  test "rejects a nonnumeric pull request URL" do
    assert {:error, :invalid_pull_request_url} =
             GitHubRepository.pull_request_url("https://github.com/acme/repo/pull/latest")
  end
end
