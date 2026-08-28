defmodule IrcpipeWeb.Api.EngineErrorResponse do
  @moduledoc false

  import Plug.Conn, only: [put_status: 2]

  def respond(conn, %{code: code} = error) do
    conn
    |> put_status(status(code))
    |> Phoenix.Controller.json(%{error: public_code(error)})
  end

  defp public_code(%{code: :invalid_state, details: %{reason: reason}})
       when is_binary(reason),
       do: reason

  defp public_code(%{code: :invalid_state, details: %{code: code}}) when is_binary(code),
    do: code

  defp public_code(%{code: code}), do: code

  defp status(code) when code in [:engine_unavailable, :not_connected, :timeout],
    do: :service_unavailable

  defp status(:unauthorized), do: :not_found
  defp status(:internal_error), do: :bad_gateway
  defp status(_code), do: :unprocessable_entity
end
