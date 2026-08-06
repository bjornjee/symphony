defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @team_send_tool "team_send"
  @team_send_kinds ~w(update handoff check blocker)
  @team_send_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["recipient", "kind", "message"],
    "properties" => %{
      "recipient" => %{"type" => "string", "minLength" => 1},
      "kind" => %{"type" => "string", "enum" => @team_send_kinds},
      "message" => %{"type" => "string", "minLength" => 1, "maxLength" => 4_096}
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @team_send_tool ->
        execute_team_send(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names(opts)
          }
        })
    end
  end

  @spec tool_specs(keyword()) :: [map()]
  def tool_specs(opts \\ []) do
    specs = [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]

    if Keyword.get(opts, :team_send, false) do
      specs ++
        [
          %{
            "name" => @team_send_tool,
            "description" => "Send a bounded update, handoff, check, or blocker to another agent in this Team Mode request.",
            "inputSchema" => @team_send_input_schema
          }
        ]
    else
      specs
    end
  end

  defp execute_team_send(arguments, opts) do
    callback = Keyword.get(opts, :team_send)

    with {:ok, recipient, kind, message} <- normalize_team_send_arguments(arguments),
         true <- is_function(callback, 3) || {:error, :team_send_unavailable},
         {:ok, event} <- callback.(recipient, kind, message) do
      event_id = Map.get(event, :id) || Map.get(event, "id")
      dynamic_tool_response(true, encode_payload(%{"eventId" => event_id}))
    else
      {:error, reason} -> failure_response(team_send_error_payload(reason))
    end
  end

  defp normalize_team_send_arguments(arguments) when is_map(arguments) do
    recipient = Map.get(arguments, "recipient") || Map.get(arguments, :recipient)
    kind = Map.get(arguments, "kind") || Map.get(arguments, :kind)
    message = Map.get(arguments, "message") || Map.get(arguments, :message)

    case {normalize_team_recipient(recipient), normalize_team_kind(kind), normalize_team_message(message)} do
      {{:ok, recipient}, {:ok, kind}, {:ok, message}} -> {:ok, recipient, kind, message}
      _invalid -> {:error, :invalid_team_send_arguments}
    end
  end

  defp normalize_team_send_arguments(_arguments), do: {:error, :invalid_team_send_arguments}

  defp normalize_team_recipient(recipient) when is_binary(recipient) do
    case String.trim(recipient) do
      "" -> :error
      recipient -> {:ok, recipient}
    end
  end

  defp normalize_team_recipient(_recipient), do: :error

  defp normalize_team_kind(kind) when kind in @team_send_kinds, do: {:ok, kind}
  defp normalize_team_kind(_kind), do: :error

  defp normalize_team_message(message) when is_binary(message) and byte_size(message) <= 4_096 do
    case String.trim(message) do
      "" -> :error
      _content -> {:ok, message}
    end
  end

  defp normalize_team_message(_message), do: :error

  defp team_send_error_payload(:invalid_team_send_arguments) do
    %{"error" => %{"code" => "invalid_team_send_arguments", "message" => "`team_send` arguments are invalid."}}
  end

  defp team_send_error_payload(:recipient_completed) do
    %{"error" => %{"code" => "recipient_completed", "message" => "Team message recipient has already completed."}}
  end

  defp team_send_error_payload(:unknown_recipient) do
    %{"error" => %{"code" => "unknown_recipient", "message" => "Team message recipient is unknown."}}
  end

  defp team_send_error_payload(reason) when is_atom(reason) do
    %{"error" => %{"code" => Atom.to_string(reason), "message" => "Team message was not delivered."}}
  end

  defp team_send_error_payload(_reason) do
    %{"error" => %{"code" => "delivery_failed", "message" => "Team message was not delivered."}}
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `workflow.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names(opts) do
    Enum.map(tool_specs(team_send: Keyword.has_key?(opts, :team_send)), & &1["name"])
  end
end
