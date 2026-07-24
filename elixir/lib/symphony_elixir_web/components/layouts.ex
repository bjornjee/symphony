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

                this.updateLogFollowState = function () {
                  var log = this.el.querySelector("#agent-detail-log");
                  var indicator = this.el.querySelector("[data-log-follow-state]");
                  if (!log || !indicator) return;

                  var following =
                    log.scrollHeight - log.clientHeight - log.scrollTop <= 24;
                  indicator.dataset.logFollowState = following ? "following" : "paused";
                  indicator.textContent = following ? "Following" : "Paused";
                }.bind(this);

                this.logScrollHandler = this.updateLogFollowState;
                this.bindLogScroll = function () {
                  var log = this.el.querySelector("#agent-detail-log");
                  if (this.logElement === log) return;

                  if (this.logElement) {
                    this.logElement.removeEventListener("scroll", this.logScrollHandler);
                  }

                  this.logElement = log;
                  if (this.logElement) {
                    this.logElement.addEventListener("scroll", this.logScrollHandler, {
                      passive: true
                    });
                  }
                }.bind(this);

                this.bindLogScroll();
                var log = this.el.querySelector("#agent-detail-log");
                if (log) log.scrollTop = log.scrollHeight;
                this.updateLogFollowState();
                var detail = this.el.querySelector("#agent-detail");
                this.selectedAgentId = detail ? detail.dataset.selectedAgent : null;
              },
              beforeUpdate: function () {
                var timeline = this.el.querySelector("#agent-detail-timeline");
                var log = this.el.querySelector("#agent-detail-log");
                var detail = this.el.querySelector("#agent-detail");
                this.timelineScrollTop = timeline ? timeline.scrollTop : null;
                this.logScrollTop = log ? log.scrollTop : null;
                this.logShouldFollow = log
                  ? log.scrollHeight - log.clientHeight - log.scrollTop <= 24
                  : false;
                this.selectedAgentId = detail ? detail.dataset.selectedAgent : null;
                this.focusedId =
                  this.el.contains(document.activeElement) && document.activeElement.id
                    ? document.activeElement.id
                    : null;
              },
              updated: function () {
                var timelineScrollTop = this.timelineScrollTop;
                var logScrollTop = this.logScrollTop;
                var logShouldFollow = this.logShouldFollow;
                var focusedId = this.focusedId;

                window.requestAnimationFrame(function () {
                  var timeline = document.querySelector("#agent-detail-timeline");
                  if (timeline && timelineScrollTop !== null) {
                    timeline.scrollTop = timelineScrollTop;
                  }

                  var log = document.querySelector("#agent-detail-log");
                  var detail = document.querySelector("#agent-detail");
                  var selectedAgentId = detail ? detail.dataset.selectedAgent : null;
                  if (log && logScrollTop !== null) {
                    log.scrollTop =
                      logShouldFollow || selectedAgentId !== this.selectedAgentId
                        ? log.scrollHeight
                        : logScrollTop;
                  }
                  this.bindLogScroll();
                  this.updateLogFollowState();

                  var focused = focusedId ? document.getElementById(focusedId) : null;
                  if (focused && document.activeElement !== focused) {
                    focused.focus({preventScroll: true});
                  }
                }.bind(this));
              },
              destroyed: function () {
                this.el.removeEventListener("click", this.copyHandler);
                if (this.logElement) {
                  this.logElement.removeEventListener("scroll", this.logScrollHandler);
                }
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
