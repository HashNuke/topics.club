defmodule Ircpipe.Irc.Commands do
  @moduledoc """
  IRC slash command parsing and lightweight suggestions.

  The web client can use these definitions to keep command help close to the
  backend parser that will eventually execute the commands.
  """

  @commands [
    %{
      name: "/join",
      command: "join",
      usage: "/join #channel",
      description: "Join a channel",
      required_permission: "user",
      examples: ["/join #elixir"]
    },
    %{
      name: "/list",
      command: "list",
      usage: "/list",
      description: "Browse channels on this server",
      required_permission: "user",
      examples: ["/list"]
    },
    %{
      name: "/part",
      command: "part",
      usage: "/part #channel",
      description: "Leave a channel",
      required_permission: "user",
      examples: ["/part #elixir"]
    },
    %{
      name: "/leave",
      command: "leave",
      usage: "/leave #channel",
      description: "Leave a channel",
      required_permission: "user",
      examples: ["/leave #elixir"]
    },
    %{
      name: "/msg",
      command: "msg",
      usage: "/msg nick message",
      description: "Send a private message",
      required_permission: "user",
      examples: ["/msg NickServ help"]
    },
    %{
      name: "/me",
      command: "me",
      usage: "/me action",
      description: "Send an action message",
      required_permission: "user",
      examples: ["/me waves"]
    },
    %{
      name: "/nick",
      command: "nick",
      usage: "/nick newnick",
      description: "Change nickname",
      required_permission: "user",
      examples: ["/nick mira_"]
    },
    %{
      name: "/topic",
      command: "topic",
      usage: "/topic #channel text",
      description: "Set or view a topic",
      required_permission: "channel_operator",
      examples: ["/topic #elixir Releases and OTP"]
    },
    %{
      name: "/quote",
      command: "quote",
      usage: "/quote RAW COMMAND",
      description: "Send a raw IRC command",
      required_permission: "advanced_user",
      examples: ["/quote WHO #elixir"]
    }
  ]

  @doc """
  Returns matching commands when the input begins with a slash command prefix.
  """
  def suggest(input) when is_binary(input) do
    case String.trim_leading(input) do
      "/" <> rest ->
        prefix =
          rest
          |> String.split(~r/\s+/, parts: 2)
          |> List.first()
          |> String.downcase()

        @commands
        |> Enum.filter(fn command ->
          command.command != "" and String.starts_with?(command.command, prefix)
        end)
        |> Enum.map(&Map.drop(&1, [:command]))

      _ ->
        []
    end
  end

  def suggest(_input), do: []

  @doc """
  Parses a supported slash command into a normalized command name and args.
  """
  def parse(input) when is_binary(input) do
    input = String.trim(input)

    with "/" <> command_line <- input,
         [name | rest] <- String.split(command_line, ~r/\s+/, parts: 2),
         true <- known_command?(name) do
      {:ok,
       %{
         name: name,
         args: parse_args(name, List.first(rest) || "")
       }
       |> Map.merge(command_metadata(name))}
    else
      false -> {:error, {:unknown_command, command_name(input)}}
      _ -> {:error, :not_a_command}
    end
  end

  def parse(_input), do: {:error, :not_a_command}

  def all, do: Enum.map(@commands, &Map.drop(&1, [:command]))

  defp known_command?(name), do: Enum.any?(@commands, &(&1.command == name))

  defp command_metadata(name) do
    @commands
    |> Enum.find(&(&1.command == name))
    |> Map.drop([:command, :name])
  end

  defp parse_args(name, args) when name in ["me", "quote"] do
    args
    |> String.trim()
    |> case do
      "" -> []
      text -> [text]
    end
  end

  defp parse_args("msg", args) do
    case String.split(String.trim(args), ~r/\s+/, parts: 2) do
      [""] -> []
      [target] -> [target]
      [target, body] -> [target, body]
    end
  end

  defp parse_args(_name, args) do
    args
    |> String.split(~r/\s+/, trim: true)
  end

  defp command_name("/" <> command_line) do
    command_line
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
  end

  defp command_name(_input), do: nil
end
