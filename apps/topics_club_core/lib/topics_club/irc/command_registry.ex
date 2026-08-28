defmodule TopicsClub.Irc.CommandRegistry do
  @moduledoc """
  Combines ircxd's protocol metadata with topics.club execution policy.

  IRC wire parsing and protocol classification stay in ircxd. This module owns
  only the product decision to enable, manage, or deny a parsed command.
  """

  alias Ircxd.{ClientCommand, CommandSpec, ISupport, Message}

  @managed_commands ~w(JOIN NICK NOTICE PART PRIVMSG TOPIC)
  @query_commands ~w(ADMIN HELP INFO ISON LINKS LIST LUSERS MOTD NAMES STATS TIME TRACE USERHOST USERS VERSION WHO WHOIS WHOWAS)
  @application_only_denies ~w(DIE ERROR PING PONG SERVICE STARTTLS USER WEBIRC)

  @arity %{
    "ADMIN" => 0..1,
    "AWAY" => 0..1,
    "HELP" => 0..1,
    "INFO" => 0..1,
    "INVITE" => 2..2,
    "ISON" => 1..15,
    "JOIN" => 1..2,
    "KICK" => 2..3,
    "LINKS" => 0..2,
    "LIST" => 0..2,
    "LUSERS" => 0..2,
    "MODE" => 1..15,
    "MOTD" => 0..1,
    "NAMES" => 0..1,
    "NICK" => 1..1,
    "NOTICE" => 2..2,
    "PART" => 1..2,
    "PRIVMSG" => 2..2,
    "QUIT" => 0..1,
    "STATS" => 0..2,
    "TIME" => 0..1,
    "TOPIC" => 1..2,
    "TRACE" => 0..1,
    "USERHOST" => 1..5,
    "USERS" => 0..1,
    "VERSION" => 0..1,
    "WHO" => 1..2,
    "WHOIS" => 1..2,
    "WHOWAS" => 1..3
  }

  def validate_private_message(targets, body) when is_binary(targets) and is_binary(body) do
    validate_product_policy(%Message{command: "PRIVMSG", params: [targets, body]})
  end

  def validate_chat_message(body) when is_binary(body) do
    with :ok <- validate_message_body("PRIVMSG", body) do
      if String.contains?(body, <<1>>) do
        {:error,
         policy_error(
           "unsupported_ctcp",
           "PRIVMSG",
           "CTCP and DCC payloads are not accepted as ordinary chat messages."
         )}
      else
        :ok
      end
    end
  end

  def validate_chat_message(_body),
    do: {:error, policy_error("invalid_arguments", "PRIVMSG", "Message text is invalid.")}

  def validate_managed_body("PRIVMSG", <<1, "ACTION ", rest::binary>> = body) do
    logical_body =
      if String.ends_with?(rest, <<1>>) do
        binary_part(rest, 0, byte_size(rest) - 1)
      else
        body
      end

    validate_message_body("PRIVMSG", logical_body)
  end

  def validate_managed_body(command, body)
      when command in ["PRIVMSG", "NOTICE"] and is_binary(body) do
    validate_message_body(command, body)
  end

  def validate_managed_body(command, _body) when command in ["PRIVMSG", "NOTICE"] do
    {:error, policy_error("invalid_arguments", command, "Message text is invalid.")}
  end

  defp validate_message_body(command, body) do
    if String.trim(body) == "" do
      {:error, policy_error("invalid_arguments", command, "Message text cannot be empty.")}
    else
      :ok
    end
  end

  def validate_join_channel(channel, client_info \\ %{isupport: %{}})

  def validate_join_channel(channel, client_info) when is_binary(channel) do
    with {:ok, %{message: %Message{params: [parsed_channel]}}} <-
           resolve("JOIN " <> channel, client_info),
         true <- parsed_channel == channel,
         true <- ISupport.channel?(Map.get(client_info, :isupport, %{}), channel) do
      :ok
    else
      {:error, error} ->
        {:error, error}

      _error ->
        {:error,
         policy_error(
           "invalid_arguments",
           "JOIN",
           "Join exactly one valid channel without a key."
         )}
    end
  end

  def validate_join_channel(_channel, _client_info),
    do: {:error, policy_error("invalid_arguments", "JOIN", "Channel is invalid.")}

  def validate_join_channel_syntax(channel) when is_binary(channel) do
    if String.match?(channel, ~r/\A[^A-Za-z0-9\s,:\x00\x07][^\s,\x00\x07]*\z/u) do
      :ok
    else
      {:error, policy_error("invalid_arguments", "JOIN", "Channel is invalid.")}
    end
  end

  def validate_join_channel_syntax(_channel),
    do: {:error, policy_error("invalid_arguments", "JOIN", "Channel is invalid.")}

  def resolve(line, client_info) when is_binary(line) do
    with {:ok, message} <- ClientCommand.parse(line),
         spec = CommandSpec.classify(message.command, message.params, client_info),
         :ok <- validate_known(message.command, spec),
         :ok <- validate_arity(message),
         :ok <- validate_product_policy(message),
         {:ok, disposition} <- disposition(message.command, spec) do
      {:ok,
       %{
         message: message,
         spec: spec,
         disposition: disposition,
         display: redacted_display(message, spec)
       }}
    else
      {:error, %{code: _code} = error} -> {:error, error}
      {:error, reason} -> {:error, parser_error(reason)}
    end
  end

  def resolve(_line, _client_info), do: {:error, parser_error(:invalid_line)}

  defp validate_known(_command, %{known?: true}), do: :ok

  defp validate_known(command, _spec) when command in @application_only_denies do
    {:error, policy_error("protocol_owned", command, "ircxd owns this protocol command.")}
  end

  defp validate_known(command, _spec) do
    {:error, policy_error("unknown_command", command, "Unknown IRC command.")}
  end

  defp validate_arity(%Message{command: command, params: params}) do
    case Map.fetch(@arity, command) do
      {:ok, range} ->
        if length(params) in range do
          :ok
        else
          {:error,
           policy_error(
             "invalid_arguments",
             command,
             "Arguments do not match #{command_usage(command)}."
           )}
        end

      :error ->
        :ok
    end
  end

  defp validate_product_policy(%Message{
         command: "PRIVMSG",
         params: [targets, body]
       }) do
    with :ok <- validate_managed_body("PRIVMSG", body) do
      cond do
        service_target?(targets) and credential_message?(body) ->
          {:error,
           policy_error(
             "credential_bearing",
             "PRIVMSG",
             "Known service credential commands are blocked because message history is retained."
           )}

        unsupported_ctcp?(body) ->
          {:error,
           policy_error(
             "unsupported_ctcp",
             "PRIVMSG",
             "Only CTCP ACTION is available; DCC and other CTCP commands are disabled."
           )}

        true ->
          :ok
      end
    end
  end

  defp validate_product_policy(%Message{command: "NOTICE", params: [_targets, body]}) do
    validate_managed_body("NOTICE", body)
  end

  defp validate_product_policy(%Message{command: "JOIN", params: [channels | _rest]}) do
    targets = String.split(channels, ",", trim: true)

    cond do
      "0" in targets ->
        {:error,
         policy_error(
           "not_yet_managed",
           "JOIN",
           "JOIN 0 is disabled until leave-all reconciliation is implemented."
         )}

      length(targets) != 1 ->
        {:error,
         policy_error(
           "not_yet_managed",
           "JOIN",
           "Multi-channel JOIN is disabled until per-target outcomes are implemented."
         )}

      true ->
        :ok
    end
  end

  defp validate_product_policy(%Message{command: "PART", params: [channels | _rest]}) do
    if length(String.split(channels, ",", trim: true)) != 1 do
      {:error,
       policy_error(
         "not_yet_managed",
         "PART",
         "Multi-channel PART is disabled until per-target outcomes are implemented."
       )}
    else
      :ok
    end
  end

  defp validate_product_policy(%Message{}), do: :ok

  defp service_target?(targets) do
    targets
    |> String.split(",", trim: true)
    |> Enum.any?(&String.match?(&1, ~r/(?:nick|chan|host|memo)serv(?:@|$)/i))
  end

  defp credential_message?(body) do
    command =
      body
      |> String.trim_leading()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> String.upcase()

    command in ~w(IDENTIFY GHOST RECOVER REGAIN REGISTER RELEASE SET)
  end

  defp unsupported_ctcp?(<<1, "ACTION ", rest::binary>>) do
    if String.ends_with?(rest, <<1>>) do
      action = binary_part(rest, 0, byte_size(rest) - 1)
      String.contains?(action, <<1>>)
    else
      true
    end
  end

  defp unsupported_ctcp?(<<1, _rest::binary>>), do: true
  defp unsupported_ctcp?(body), do: String.contains?(body, <<1>>)

  defp disposition(command, _spec) when command in @managed_commands,
    do: {:ok, :managed}

  defp disposition(command, _spec) when command in @query_commands,
    do: {:ok, :query}

  defp disposition(command, %{family: :protocol}) do
    {:error, policy_error("protocol_owned", command, "ircxd owns this protocol command.")}
  end

  defp disposition(command, %{family: :registration}) do
    {:error,
     policy_error(
       "credential_bearing",
       command,
       "This registration or credential command is not available through /quote."
     )}
  end

  defp disposition(command, %{family: :operator}) do
    {:error,
     policy_error("operator_only", command, "IRC operator commands are disabled by policy.")}
  end

  defp disposition(command, _spec) do
    {:error,
     policy_error(
       "not_yet_managed",
       command,
       "This IRC command is disabled until its application behavior is managed."
     )}
  end

  defp redacted_display(%Message{} = message, spec) do
    sensitive_positions = Map.get(spec, :sensitive_positions, [])

    params =
      message.params
      |> Enum.with_index()
      |> Enum.map(fn {param, index} ->
        if index in sensitive_positions, do: "[redacted]", else: param
      end)

    message
    |> Map.put(:params, params)
    |> Message.serialize()
    |> String.trim_trailing("\r\n")
  end

  defp parser_error(reason) do
    %{
      code: "invalid_raw_command",
      message: parser_error_message(reason),
      recoverable: true,
      detail: to_string(reason)
    }
  end

  defp parser_error_message(:empty), do: "Enter an IRC command after /quote."

  defp parser_error_message(:line_break_not_allowed),
    do: "IRC commands cannot contain line breaks."

  defp parser_error_message(:nul_not_allowed), do: "IRC commands cannot contain NUL bytes."

  defp parser_error_message(:source_not_allowed),
    do: "Client-supplied IRC source prefixes are not allowed."

  defp parser_error_message(:numeric_command_not_allowed),
    do: "Three-digit numerics are server replies, not client commands."

  defp parser_error_message(:tags_not_allowed), do: "Raw IRC message tags are not allowed."
  defp parser_error_message(:too_many_params), do: "The IRC command has too many parameters."
  defp parser_error_message(:line_too_long), do: "The IRC command exceeds the server wire limit."
  defp parser_error_message(_reason), do: "The IRC command is not valid."

  defp policy_error(code, command, message) do
    %{
      code: code,
      command: command,
      message: message,
      usage: command_usage(command),
      recoverable: code in ["invalid_arguments", "not_yet_managed"]
    }
  end

  defp command_usage(command) do
    case CommandSpec.get(command) do
      %{known?: true, syntax: syntax} -> String.trim("#{command} #{syntax}")
      _spec -> command
    end
  end
end
