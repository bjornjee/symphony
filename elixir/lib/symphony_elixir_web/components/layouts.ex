defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:dashboard_css_url, SymphonyElixirWeb.StaticAssets.dashboard_css_url())
      |> assign(:favicon_url, SymphonyElixirWeb.StaticAssets.favicon_url())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <link rel="icon" type="image/png" sizes="128x128" href={@favicon_url} />
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var PreserveDashboardReadingPosition = {
              mounted: function () {
                this.copyHandler = function (event) {
                  var button = event.target.closest("[data-copy]");
                  if (!button) return;

                  var copyStatus = document.querySelector("[data-copy-status]");
                  var copyName = button.dataset.copyName || "value";

                  if (!navigator.clipboard) {
                    if (copyStatus) {
                      copyStatus.textContent =
                        "Copy unavailable. Select and copy the value manually.";
                    }
                    return;
                  }

                  navigator.clipboard.writeText(button.dataset.copy).then(function () {
                    if (copyStatus) {
                      copyStatus.textContent = "Copied " + copyName + ".";
                    }
                  }).catch(function () {
                    if (copyStatus) {
                      copyStatus.textContent =
                        "Copy failed. Select and copy the value manually.";
                    }
                  });
                };

                this.el.addEventListener("click", this.copyHandler);
              },
              beforeUpdate: function () {
                var timeline = this.el.querySelector("#agent-detail-timeline");
                this.timelineScrollTop = timeline ? timeline.scrollTop : null;
                this.focusedId =
                  this.el.contains(document.activeElement) && document.activeElement.id
                    ? document.activeElement.id
                    : null;
              },
              updated: function () {
                var timelineScrollTop = this.timelineScrollTop;
                var focusedId = this.focusedId;

                window.requestAnimationFrame(function () {
                  var timeline = document.querySelector("#agent-detail-timeline");
                  if (timeline && timelineScrollTop !== null) {
                    timeline.scrollTop = timelineScrollTop;
                  }

                  var focused = focusedId ? document.getElementById(focusedId) : null;
                  if (focused && document.activeElement !== focused) {
                    focused.focus({preventScroll: true});
                  }
                });
              },
              destroyed: function () {
                this.el.removeEventListener("click", this.copyHandler);
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: {PreserveDashboardReadingPosition: PreserveDashboardReadingPosition}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={@dashboard_css_url} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
