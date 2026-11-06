defmodule ChatServerWeb.Router do
  use ChatServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ChatServerWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  pipeline :authenticated do
    plug ChatServerWeb.Plugs.Authenticate
  end

  scope "/api/v1", ChatServerWeb do
    pipe_through :api

    post "/auth/request_otp", AuthController, :request_otp
    post "/auth/verify_otp", AuthController, :verify_otp
    post "/auth/refresh", AuthController, :refresh
  end

  scope "/api/v1", ChatServerWeb do
    pipe_through [:api, :authenticated]

    post "/auth/logout", AuthController, :logout

    get "/me", MeController, :show
    patch "/me", MeController, :update

    post "/devices/push_token", DeviceController, :push_token
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:chat_server, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: ChatServerWeb.Telemetry
    end
  end
end
