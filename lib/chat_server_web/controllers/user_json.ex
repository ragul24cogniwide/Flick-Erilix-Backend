defmodule ChatServerWeb.UserJSON do
  @moduledoc "JSON shape of a user's own profile."

  def user(user) do
    %{
      id: user.id,
      phone: user.phone,
      display_name: user.display_name,
      about: user.about
    }
  end
end
