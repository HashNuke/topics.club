defmodule Ircpipe.Repo.Migrations.EncryptServerConnectionCredentials do
  use Ecto.Migration

  def up do
    ensure_vault_started!()

    alter table(:server_connections) do
      add :encrypted_server_password, :binary
      add :encrypted_sasl_password, :binary
    end

    flush()
    backfill_encrypted_credentials()

    alter table(:server_connections) do
      remove :server_password
      remove :sasl_password
    end

    rename table(:server_connections), :encrypted_server_password, to: :server_password
    rename table(:server_connections), :encrypted_sasl_password, to: :sasl_password
  end

  def down do
    ensure_vault_started!()

    alter table(:server_connections) do
      add :plaintext_server_password, :string
      add :plaintext_sasl_password, :string
    end

    flush()
    backfill_plaintext_credentials()

    alter table(:server_connections) do
      remove :server_password
      remove :sasl_password
    end

    rename table(:server_connections), :plaintext_server_password, to: :server_password
    rename table(:server_connections), :plaintext_sasl_password, to: :sasl_password
  end

  defp backfill_encrypted_credentials do
    %{rows: rows} =
      repo().query!("SELECT id, server_password, sasl_password FROM server_connections", [],
        log: false
      )

    Enum.each(rows, fn [id, server_password, sasl_password] ->
      repo().query!(
        """
        UPDATE server_connections
        SET encrypted_server_password = $1, encrypted_sasl_password = $2
        WHERE id = $3
        """,
        [encrypt(server_password), encrypt(sasl_password), id],
        log: false
      )
    end)
  end

  defp backfill_plaintext_credentials do
    %{rows: rows} =
      repo().query!("SELECT id, server_password, sasl_password FROM server_connections", [],
        log: false
      )

    Enum.each(rows, fn [id, server_password, sasl_password] ->
      repo().query!(
        """
        UPDATE server_connections
        SET plaintext_server_password = $1, plaintext_sasl_password = $2
        WHERE id = $3
        """,
        [decrypt(server_password), decrypt(sasl_password), id],
        log: false
      )
    end)
  end

  defp encrypt(nil), do: nil
  defp encrypt(plaintext), do: Ircpipe.Vault.encrypt!(plaintext)

  defp decrypt(nil), do: nil
  defp decrypt(ciphertext), do: Ircpipe.Vault.decrypt!(ciphertext)

  defp ensure_vault_started! do
    case Ircpipe.Vault.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
