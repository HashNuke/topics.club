defmodule TopicsClub.Wirekeeper.TestCertificate do
  @moduledoc false

  def ensure! do
    paths = paths()

    required_files =
      paths
      |> Map.take([:ca_certificate, :ca_key, :server_certificate, :server_key])
      |> Map.values()

    unless Enum.all?(required_files, &File.regular?/1) do
      generate!(paths)
    end

    paths
  end

  def paths do
    directory = Path.join(Mix.Project.build_path(), "topics_club_wirekeeper_tls")

    %{
      directory: directory,
      ca_certificate: Path.join(directory, "ca-cert.pem"),
      ca_key: Path.join(directory, "ca-key.pem"),
      server_certificate: Path.join(directory, "server-cert.pem"),
      server_key: Path.join(directory, "server-key.pem"),
      server_request: Path.join(directory, "server.csr")
    }
  end

  defp generate!(paths) do
    openssl =
      System.find_executable("openssl") ||
        raise "openssl is required to generate the Wirekeeper TLS test certificate"

    File.mkdir_p!(paths.directory)

    run!(openssl, [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-sha256",
      "-nodes",
      "-days",
      "3650",
      "-subj",
      "/CN=TopicsClub Wirekeeper Test CA",
      "-addext",
      "basicConstraints=critical,CA:TRUE",
      "-addext",
      "keyUsage=critical,keyCertSign,cRLSign",
      "-keyout",
      paths.ca_key,
      "-out",
      paths.ca_certificate
    ])

    run!(openssl, [
      "req",
      "-newkey",
      "rsa:2048",
      "-sha256",
      "-nodes",
      "-subj",
      "/CN=localhost",
      "-addext",
      "subjectAltName=DNS:localhost,IP:127.0.0.1",
      "-addext",
      "basicConstraints=critical,CA:FALSE",
      "-addext",
      "keyUsage=critical,digitalSignature,keyEncipherment",
      "-addext",
      "extendedKeyUsage=serverAuth",
      "-keyout",
      paths.server_key,
      "-out",
      paths.server_request
    ])

    run!(openssl, [
      "x509",
      "-req",
      "-sha256",
      "-days",
      "3650",
      "-in",
      paths.server_request,
      "-CA",
      paths.ca_certificate,
      "-CAkey",
      paths.ca_key,
      "-CAcreateserial",
      "-copy_extensions",
      "copy",
      "-out",
      paths.server_certificate
    ])
  end

  defp run!(executable, arguments) do
    case System.cmd(executable, arguments, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "openssl exited with #{status}: #{String.trim(output)}"
    end
  end
end
