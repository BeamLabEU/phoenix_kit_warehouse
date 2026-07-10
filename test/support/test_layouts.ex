defmodule PhoenixKitWarehouse.Test.Layouts do
  @moduledoc """
  Minimal layouts for the LiveView test endpoint. Real layouts live in the
  host app and phoenix_kit core — these just wrap LiveView content in an
  HTML shell so Phoenix.LiveViewTest can render it.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Test</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <div :if={msg = Phoenix.Flash.get(@flash, :info)} id="flash-info">{msg}</div>
    <div :if={msg = Phoenix.Flash.get(@flash, :error)} id="flash-error">{msg}</div>
    <div :if={msg = Phoenix.Flash.get(@flash, :warning)} id="flash-warning">{msg}</div>
    {@inner_content}
    """
  end

  def render(_template, assigns) do
    ~H"""
    <html>
      <body>
        <h1>Error</h1>
        <pre>{inspect(assigns[:reason] || assigns[:conn])}</pre>
      </body>
    </html>
    """
  end
end
