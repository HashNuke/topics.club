defmodule TopicsClub.Notifications.VapidKeypair do
  @moduledoc false

  @p256_order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  def valid?(encoded_public, encoded_private)
      when is_binary(encoded_public) and is_binary(encoded_private) do
    with {:ok, <<4, _coordinates::binary-size(64)>> = public_key} <-
           Base.url_decode64(encoded_public, padding: false),
         {:ok, <<_scalar::binary-size(32)>> = private_key} <-
           Base.url_decode64(encoded_private, padding: false),
         scalar = :binary.decode_unsigned(private_key),
         true <- scalar > 0 and scalar < @p256_order,
         {derived_public, ^private_key} <-
           :crypto.generate_key(:ecdh, :prime256v1, private_key) do
      derived_public == public_key
    else
      _invalid -> false
    end
  rescue
    _error -> false
  end

  def valid?(_encoded_public, _encoded_private), do: false
end
