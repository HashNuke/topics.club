defmodule TopicsClubWeb.AuthController do
  use TopicsClubWeb, :controller

  plug Ueberauth

  alias TopicsClub.Accounts
  alias TopicsClubWeb.UserAuth
  alias Ueberauth.Auth
  alias Ueberauth.Failure

  def request(conn, _params), do: conn

  def callback(%{assigns: %{ueberauth_failure: %Failure{}}} = conn, _params) do
    conn
    |> put_flash(:error, "OAuth sign in failed.")
    |> redirect(to: ~p"/users/log-in")
  end

  def callback(%{assigns: %{ueberauth_auth: %Auth{} = auth}} = conn, params) do
    case Accounts.get_or_register_oauth_user(auth) do
      {:ok, user} ->
        conn
        |> put_session(:user_return_to, get_session(conn, :user_return_to) || ~p"/chat")
        |> put_flash(:info, "Signed in with #{provider_name(auth.provider)}.")
        |> UserAuth.log_in_user(user, params)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "OAuth sign in did not return a usable email address.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp provider_name(provider) do
    provider
    |> Atom.to_string()
    |> String.capitalize()
  end
end
