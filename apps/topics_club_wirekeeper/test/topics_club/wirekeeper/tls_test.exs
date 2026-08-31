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
end
