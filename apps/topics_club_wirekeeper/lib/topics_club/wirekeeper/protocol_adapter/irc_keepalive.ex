defmodule TopicsClub.Wirekeeper.ProtocolAdapter.IrcKeepalive do
  @moduledoc """
  Frames IRC lines and answers server `PING` messages at the socket-owning layer.

  Valid IRCv3 tags and IRC prefixes are skipped before identifying the command. A handled `PING`
  is converted into an upstream `PONG` action and is never forwarded to the consumer, preventing
  duplicate replies. Every other complete line is forwarded byte-for-byte.
  """

  @behaviour TopicsClub.Wirekeeper.ProtocolAdapter

  @default_max_line_bytes 16_384

  defstruct buffer: "", max_line_bytes: @default_max_line_bytes

  @type t :: %__MODULE__{buffer: binary(), max_line_bytes: pos_integer()}

  @impl true
  def init(opts) do
    max_line_bytes = Keyword.get(opts, :max_line_bytes, @default_max_line_bytes)

    if is_integer(max_line_bytes) and max_line_bytes > 0 do
      {:ok, %__MODULE__{max_line_bytes: max_line_bytes}}
    else
      raise ArgumentError, ":max_line_bytes must be a positive integer"
    end
  end

  @impl true
  def handle_inbound(data, %__MODULE__{} = state) when is_binary(data) do
    combined = state.buffer <> data

    case take_complete_lines(combined, state.max_line_bytes, []) do
      {:ok, lines, buffer} ->
        actions = Enum.map(lines, &line_action/1)
        {:ok, actions, %{state | buffer: buffer}}

      {:error, :line_too_long, lines} ->
        actions = Enum.map(lines, &line_action/1)
        {:error, :line_too_long, actions, %{state | buffer: ""}}
    end
  end

  defp take_complete_lines(data, max_line_bytes, lines) do
    case :binary.match(data, "\n") do
      {newline_index, 1} ->
        line_bytes = newline_index + 1

        if line_bytes > max_line_bytes do
          {:error, :line_too_long, Enum.reverse(lines)}
        else
          line = binary_part(data, 0, line_bytes)
          rest = binary_part(data, line_bytes, byte_size(data) - line_bytes)
          take_complete_lines(rest, max_line_bytes, [line | lines])
        end

      :nomatch when byte_size(data) > max_line_bytes ->
        {:error, :line_too_long, Enum.reverse(lines)}

      :nomatch ->
        {:ok, Enum.reverse(lines), :binary.copy(data)}
    end
  end

  defp line_action(line) do
    case ping_parameters(line) do
      {:ok, parameters} -> {:reply, "PONG " <> parameters <> "\r\n"}
      :not_ping -> {:forward, line}
    end
  end

  defp ping_parameters(line) do
    with {:ok, without_tags} <- drop_optional_section(strip_line_ending(line), ?@),
         {:ok, without_prefix} <- drop_optional_section(without_tags, ?:),
         {command, parameters} <- split_command(without_prefix),
         true <- ascii_upcase(command) == "PING" and parameters != "" do
      {:ok, parameters}
    else
      _not_ping -> :not_ping
    end
  end

  defp strip_line_ending(line) when byte_size(line) >= 2 do
    case line do
      <<body::binary-size(byte_size(line) - 2), "\r\n">> -> body
      _other_ending -> strip_newline(line)
    end
  end

  defp strip_line_ending(line), do: strip_newline(line)

  defp strip_newline(line) when byte_size(line) >= 1 do
    case line do
      <<body::binary-size(byte_size(line) - 1), "\n">> -> body
      _other_ending -> line
    end
  end

  defp strip_newline(line), do: line

  defp drop_optional_section(data, marker) do
    data = drop_spaces(data)

    case data do
      <<^marker, rest::binary>> -> after_first_space(rest)
      _without_section -> {:ok, data}
    end
  end

  defp after_first_space(data) do
    case :binary.match(data, " ") do
      {space_index, 1} ->
        offset = space_index + 1
        {:ok, binary_part(data, offset, byte_size(data) - offset) |> drop_spaces()}

      :nomatch ->
        :invalid
    end
  end

  defp split_command(data) do
    data = drop_spaces(data)

    case :binary.match(data, " ") do
      {space_index, 1} ->
        command = binary_part(data, 0, space_index)
        offset = space_index + 1
        parameters = binary_part(data, offset, byte_size(data) - offset) |> drop_spaces()
        {command, parameters}

      :nomatch ->
        {data, ""}
    end
  end

  defp drop_spaces(<<" ", rest::binary>>), do: drop_spaces(rest)
  defp drop_spaces(data), do: data

  defp ascii_upcase(command) do
    for <<character <- command>>, into: <<>> do
      <<ascii_upcase_character(character)>>
    end
  end

  defp ascii_upcase_character(character) when character in ?a..?z, do: character - 32
  defp ascii_upcase_character(character), do: character
end
