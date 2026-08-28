defmodule TopicsClub.Irc.Session.ServerEvents do
  @moduledoc false

  alias TopicsClub.Irc.Session.EventRecorder
  alias Ircxd.Message

  def handle(event, state, %{text: text})
      when event in [:welcome, :your_host, :server_created] do
    EventRecorder.server_line(state.connection, text)
    state
  end

  def handle(event, state, %{text: text})
      when event in [:motd_start, :motd, :motd_end, :motd_missing] do
    EventRecorder.server_line(state.connection, text, "notice")
    state
  end

  def handle(:server_info, state, payload) do
    EventRecorder.server_line(
      state.connection,
      "#{payload.server} #{payload.version} user modes #{payload.user_modes} channel modes #{payload.channel_modes}",
      "notice"
    )

    state
  end

  def handle(:nick_in_use, state, payload) do
    reason = Map.get(payload, :reason) || "That nickname is already in use."
    EventRecorder.server_line(state.connection, reason, "error")
    state
  end

  def handle(:raw, state, %Message{command: command, params: params}) do
    if String.match?(command, ~r/^\d{3}$/) do
      description = List.last(params) || "No description provided."

      EventRecorder.server_line(
        state.connection,
        "IRC reply #{command}: #{description}",
        "notice",
        %{irc_event: "raw", numeric: command}
      )
    end

    state
  end
end
