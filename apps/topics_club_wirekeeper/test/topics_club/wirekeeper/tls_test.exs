defmodule TopicsClub.Wirekeeper.TlsTest do
  use ExUnit.Case, async: false

  alias TopicsClub.Wirekeeper
  alias TopicsClub.Wirekeeper.TestCertificate
  alias TopicsClub.Wirekeeper.TestTlsServer

  test "owns a hostname-verified TLS connection and relays both directions" do
    server = start_supervised!({TestTlsServer, self()})
    key = "tls-#{System.unique_integer([:positive, :monotonic])}"
    certificates = TestCertificate.ensure!()

    [certificate_entry] =
      certificates.ca_certificate
      |> File.read!()
      |> :public_key.pem_decode()

    {:Certificate, certificate_der, :not_encrypted} = certificate_entry

    assert {:ok, opened} =
             Wirekeeper.open(
               key,
               {:tls,
                host: "localhost",
                port: TestTlsServer.port(server),
                tls_options: [cacerts: [certificate_der]]}
             )

    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_tls_server, :accepted, ^server}
    assert opened.transport == :tls
    assert {:ok, _gap} = Wirekeeper.attach(key, opened.generation, self())

    assert :ok = Wirekeeper.send_data(key, opened.generation, "encrypted upstream")
    assert_receive {:wirekeeper_test_tls_server, :data, ^server, "encrypted upstream"}

    assert :ok = TestTlsServer.send_data(server, "encrypted downstream")

    assert_receive {:topics_club_wirekeeper,
                    {:data,
                     %{
                       key: ^key,
                       generation: generation,
                       payload: "encrypted downstream"
                     }}}

    assert generation == opened.generation
  end

  test "rejects a trusted certificate whose IP subject alternative name does not match" do
    server = start_supervised!({TestTlsServer, [owner: self(), ip: {0, 0, 0, 0}]})
    key = "tls-ip-mismatch-#{System.unique_integer([:positive, :monotonic])}"
    certificate = ca_certificate()

    result =
      Wirekeeper.open(
        key,
        {:tls,
         host: "127.0.0.2",
         port: TestTlsServer.port(server),
         tls_options: [cacerts: [certificate]]}
      )

    on_exit(fn -> close_if_opened(key, result) end)
    assert {:error, {:transport, _reason}} = result
  end

  test "accepts a trusted certificate whose IP subject alternative name matches" do
    server = start_supervised!({TestTlsServer, self()})
    key = "tls-ip-match-#{System.unique_integer([:positive, :monotonic])}"
    certificate = ca_certificate()

    assert {:ok, opened} =
             Wirekeeper.open(
               key,
               {:tls,
                host: "127.0.0.1",
                port: TestTlsServer.port(server),
                tls_options: [cacerts: [certificate]]}
             )

    on_exit(fn -> Wirekeeper.close(key, opened.generation) end)
    assert_receive {:wirekeeper_test_tls_server, :accepted, ^server}
  end

  test "rejects a trusted certificate whose DNS subject alternative name does not match" do
    server = start_supervised!({TestTlsServer, self()})
    key = "tls-dns-mismatch-#{System.unique_integer([:positive, :monotonic])}"
    certificate = ca_certificate()

    result =
      Wirekeeper.open(
        key,
        {:tls,
         host: "localhost.localdomain",
         port: TestTlsServer.port(server),
         tls_options: [cacerts: [certificate]]}
      )

    on_exit(fn -> close_if_opened(key, result) end)
    assert {:error, {:transport, _reason}} = result
  end

  defp ca_certificate do
    [certificate_entry] =
      TestCertificate.ensure!().ca_certificate
      |> File.read!()
      |> :public_key.pem_decode()

    {:Certificate, certificate_der, :not_encrypted} = certificate_entry
    certificate_der
  end

  defp close_if_opened(key, {:ok, opened}) do
    Wirekeeper.close(key, opened.generation)
  end

  defp close_if_opened(_key, _error), do: :ok
end
