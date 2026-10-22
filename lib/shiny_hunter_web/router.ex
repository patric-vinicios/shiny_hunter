defmodule ShinyHunterWeb.Router do
  use ShinyHunterWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ShinyHunterWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ShinyHunterWeb do
    pipe_through :browser

    live "/", HuntLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", ShinyHunterWeb do
  #   pipe_through :api
  # end
end
