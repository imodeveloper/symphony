defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live updates
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Backend online
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Disk free</p>
            <p class="metric-value numeric"><%= format_bytes(operation_value(@payload, [:disk, :available_bytes])) %></p>
            <p class="metric-detail"><%= disk_metric_detail(@payload) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Guardrail</p>
            <p class="metric-value"><%= guardrail_label(@payload) %></p>
            <p class="metric-detail"><%= guardrail_detail(@payload) %></p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Operations</h2>
              <p class="section-copy">Runtime heartbeat, disk pressure guardrail, cleanup, and stale worktree cleanup.</p>
            </div>
          </div>

          <div class="operation-grid">
            <div class="operation-item">
              <span class="operation-label">Heartbeat</span>
              <span class="operation-value mono"><%= operation_value(@payload, [:heartbeat_at]) || "n/a" %></span>
            </div>
            <div class="operation-item">
              <span class="operation-label">Disk status</span>
              <span class={operation_badge_class(operation_value(@payload, [:disk, :status]))}>
                <%= operation_value(@payload, [:disk, :status]) || "unknown" %>
              </span>
            </div>
            <div class="operation-item">
              <span class="operation-label">Disk path</span>
              <span class="operation-value mono"><%= operation_value(@payload, [:disk, :path]) || "n/a" %></span>
            </div>
            <div class="operation-item">
              <span class="operation-label">Threshold</span>
              <span class="operation-value numeric"><%= format_bytes(operation_value(@payload, [:disk, :threshold_bytes])) %></span>
            </div>
            <div class="operation-item">
              <span class="operation-label">Cleanup</span>
              <span class={operation_badge_class(operation_value(@payload, [:cleanup, :status]))}>
                <%= operation_value(@payload, [:cleanup, :status]) || "unknown" %>
              </span>
            </div>
            <div class="operation-item">
              <span class="operation-label">Stale worktrees</span>
              <span class="operation-value numeric">
                <%= stale_worktree_summary(@payload) %>
              </span>
            </div>
            <div class="operation-item">
              <span class="operation-label">Linear watchdog</span>
              <span class={operation_badge_class(operation_value(@payload, [:linear_watchdog, :status]))}>
                <%= operation_value(@payload, [:linear_watchdog, :status]) || "unknown" %>
              </span>
              <span class="operation-value">
                <%= linear_watchdog_summary(@payload) %>
              </span>
            </div>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp operation_value(payload, path) when is_map(payload) and is_list(path) do
    get_in(payload, [:operations | path])
  end

  defp operation_value(_payload, _path), do: nil

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1024 * 1024 * 1024 ->
        "#{Float.round(bytes / 1024 / 1024 / 1024, 1)} GiB"

      bytes >= 1024 * 1024 ->
        "#{Float.round(bytes / 1024 / 1024, 1)} MiB"

      true ->
        "#{bytes} B"
    end
  end

  defp format_bytes(_bytes), do: "n/a"

  defp disk_metric_detail(payload) do
    total = format_bytes(operation_value(payload, [:disk, :total_bytes]))
    checked_at = operation_value(payload, [:disk, :checked_at]) || "not checked"

    case operation_value(payload, [:disk, :used_percent]) do
      percent when is_integer(percent) -> "#{percent}% used of #{total}; checked #{checked_at}"
      _ -> "Checked #{checked_at}"
    end
  end

  defp guardrail_label(payload) do
    if operation_value(payload, [:dispatch, :paused?]) == true do
      "Paused"
    else
      "Ready"
    end
  end

  defp guardrail_detail(payload) do
    operation_value(payload, [:dispatch, :reason]) || "Dispatch is allowed."
  end

  defp stale_worktree_summary(payload) do
    status = operation_value(payload, [:stale_worktrees, :status]) || "unknown"
    scanned = operation_value(payload, [:stale_worktrees, :scanned]) || 0
    deleted = operation_value(payload, [:stale_worktrees, :deleted]) || []

    "#{status}; #{length(deleted)} deleted / #{scanned} scanned"
  end

  defp linear_watchdog_summary(payload) do
    identifier = operation_value(payload, [:linear_watchdog, :issue_identifier]) || "not created"
    action = operation_value(payload, [:linear_watchdog, :action]) || "idle"

    "#{identifier}; #{action}"
  end

  defp operation_badge_class(status) do
    base = "state-badge"
    normalized = status |> to_string() |> String.downcase()

    cond do
      normalized in ["healthy", "completed", "idle", "checked", "ready"] -> "#{base} state-badge-active"
      normalized in ["low", "running", "disabled", "missing_root"] -> "#{base} state-badge-warning"
      normalized in ["error", "failed"] -> "#{base} state-badge-danger"
      true -> base
    end
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
