defmodule SymphonyElixir.GitHubRepository do
  @moduledoc "Normalizes trusted GitHub repository and pull-request identities."

  @spec from_origin(String.t()) :: {:ok, String.t()} | {:error, :unsupported_repository_origin}
  def from_origin(origin) when is_binary(origin) do
    case Regex.run(~r/^(?:git@)?github\.com:([^\/]+)\/(.+?)(?:\.git)?$/, origin, capture: :all_but_first) do
      [owner, repo] -> normalize_repository(owner, repo)
      _ -> from_https_origin(origin)
    end
  end

  def from_origin(_origin), do: {:error, :unsupported_repository_origin}

  @spec pull_request_url(String.t()) ::
          {:ok, %{repository: String.t(), number: pos_integer()}} | {:error, :invalid_pull_request_url}
  def pull_request_url(url) when is_binary(url) do
    with %URI{scheme: "https", host: "github.com", path: path, query: nil, fragment: nil} <- URI.parse(url),
         [owner, repo, "pull", number] <- String.split(path || "", "/", trim: true),
         {number, ""} when number > 0 <- Integer.parse(number),
         {:ok, repository} <- normalize_repository(owner, repo) do
      {:ok, %{repository: repository, number: number}}
    else
      _ -> {:error, :invalid_pull_request_url}
    end
  end

  def pull_request_url(_url), do: {:error, :invalid_pull_request_url}

  defp from_https_origin(origin) do
    with %URI{scheme: "https", host: "github.com", path: path, query: nil, fragment: nil} <- URI.parse(origin),
         [owner, repo] <- String.split(path || "", "/", trim: true) do
      normalize_repository(owner, repo)
    else
      _ -> {:error, :unsupported_repository_origin}
    end
  end

  defp normalize_repository(owner, repo) do
    repo = String.trim_trailing(repo, ".git")

    if valid_component?(owner) and valid_component?(repo),
      do: {:ok, "#{owner}/#{repo}"},
      else: {:error, :unsupported_repository_origin}
  end

  defp valid_component?(component) do
    is_binary(component) and component != "" and not String.contains?(component, ["/", "\\", <<0>>])
  end
end
