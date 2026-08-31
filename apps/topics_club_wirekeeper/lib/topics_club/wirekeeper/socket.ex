defmodule TopicsClub.Wirekeeper.Socket do
  @moduledoc false

  @type socket :: {:tcp, port()} | {:tls, :ssl.sslsocket()}
  @type transport :: {:tcp | :tls, keyword()}

  @spec connect(transport()) :: {:ok, socket()} | {:error, atom()}
  def connect({:tcp, opts}) when is_list(opts) do
    with {:ok, host, port, timeout} <- connection_options(opts) do
      socket_options = [:binary, packet: :raw, active: false, nodelay: true, keepalive: true]

      case :gen_tcp.connect(String.to_charlist(host), port, socket_options, timeout) do
        {:ok, socket} -> {:ok, {:tcp, socket}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def connect({:tls, opts}) when is_list(opts) do
    with {:ok, host, port, timeout} <- connection_options(opts) do
      host_charlist = String.to_charlist(host)

      defaults = [
        mode: :binary,
        packet: :raw,
        active: false,
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ],
        server_name_indication: server_name_indication(host_charlist)
      ]

      tls_options =
        defaults
        |> Keyword.merge(Keyword.get(opts, :tls_options, []))
        |> Keyword.put(:active, false)
        |> Keyword.put(:mode, :binary)
        |> Keyword.put(:packet, :raw)

      case :ssl.connect(host_charlist, port, tls_options, timeout) do
        {:ok, socket} -> {:ok, {:tls, socket}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def connect(_transport), do: {:error, :invalid_transport}

  @spec arm(socket()) :: :ok | {:error, atom()}
  def arm({:tcp, socket}), do: :inet.setopts(socket, active: :once)
  def arm({:tls, socket}), do: :ssl.setopts(socket, active: :once)

  @spec send(socket(), iodata()) :: :ok | {:error, atom()}
  def send({:tcp, socket}, data), do: :gen_tcp.send(socket, data)
  def send({:tls, socket}, data), do: :ssl.send(socket, data)

  @spec close(socket()) :: :ok
  def close({:tcp, socket}), do: :gen_tcp.close(socket)
  def close({:tls, socket}), do: :ssl.close(socket)

  @spec transport_name(socket()) :: :tcp | :tls
  def transport_name({transport, _socket}), do: transport

  defp connection_options(opts) do
    host = Keyword.get(opts, :host)
    port = Keyword.get(opts, :port)
    timeout = Keyword.get(opts, :connect_timeout, 10_000)

    if is_binary(host) and byte_size(host) > 0 and is_integer(port) and port in 1..65_535 and
         is_integer(timeout) and timeout > 0 do
      {:ok, host, port, timeout}
    else
      {:error, :invalid_transport_options}
    end
  end

  defp server_name_indication(host) do
    case :inet.parse_address(host) do
      {:ok, _address} -> :disable
      {:error, :einval} -> host
    end
  end
end
