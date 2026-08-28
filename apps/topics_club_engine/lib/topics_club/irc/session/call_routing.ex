defmodule TopicsClub.Irc.Session.CallRouting do
  @moduledoc false

  alias TopicsClub.Irc.Session.ChannelListCommands
  alias TopicsClub.Irc.Session.CommandExecution
  alias TopicsClub.Irc.Session.DepartureCommands
  alias TopicsClub.Irc.Session.JoinRequests
  alias TopicsClub.Irc.Session.OutboundMessages

  def handle({:request_join, user, channel}, _from, state) do
    {reply, state} = JoinRequests.request(state, user, channel)
    {:reply, reply, state}
  end

  def handle(:connection_info, _from, %{client: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle(:connection_info, _from, state) do
    info = Ircxd.Client.connection_info(state.client)
    {:reply, {:ok, info}, %{state | client_info: info}}
  end

  def handle({:execute, intent, command_id, buffer_id}, _from, state) do
    {reply, state} = CommandExecution.execute(state, intent, command_id, buffer_id)
    {:reply, reply, state}
  end

  def handle(:list_channels, from, state), do: ChannelListCommands.request(state, from)

  def handle({:say, channel, body}, _from, state) do
    {reply, state} = OutboundMessages.say(state, channel, body)
    {:reply, reply, state}
  end

  def handle({:action, channel, body}, _from, state) do
    {reply, state} = OutboundMessages.action(state, channel, body)
    {:reply, reply, state}
  end

  def handle({:privmsg_thread, thread_id, body}, _from, state) do
    {reply, state} = OutboundMessages.direct(state, thread_id, body)
    {:reply, reply, state}
  end

  def handle({:part, channel, reason}, _from, state) do
    {reply, state} = DepartureCommands.part(state, channel, reason)
    {:reply, reply, state}
  end

  def handle({:quit, reason}, _from, state) do
    {reply, state} = DepartureCommands.quit(state, reason)
    {:stop, :normal, reply, state}
  end
end
