defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          simulator_pool: [],
          simulator_required_labels: %{
            "Needs Simulator" => 1,
            "Needs 2 Simulators" => 2,
            "Needs 3 Simulators" => 3
          },
          simulator_block_relation_type: "blocks",
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          observability_issue_heartbeat_enabled: false,
          observability_issue_heartbeat_interval_ms: 300_000,
          observability_issue_heartbeat_comment_marker: "symphony:heartbeat",
          observability_issue_activity_comments_enabled: false,
          observability_issue_activity_comment_interval_ms: 600_000,
          operations_disk_path: nil,
          operations_disk_pause_threshold_bytes: 5 * 1024 * 1024 * 1024,
          operations_disk_check_interval_ms: 60_000,
          operations_paused_retry_interval_ms: 60_000,
          operations_cleanup_dry_run_command: nil,
          operations_cleanup_command: nil,
          operations_cleanup_timeout_ms: 900_000,
          operations_cleanup_cooldown_ms: 1_800_000,
          operations_paused_issue_state: nil,
          operations_stale_worktree_ttl_hours: 168,
          operations_stale_worktree_check_interval_ms: 3_600_000,
          operations_stale_worktree_delete: false,
          operations_watchdog_issue_enabled: false,
          operations_watchdog_issue_interval_ms: 3_600_000,
          operations_watchdog_issue_title: "Monitor Watchdog: hourly simulator health check",
          operations_watchdog_issue_description: nil,
          operations_watchdog_issue_state: "Todo",
          operations_watchdog_issue_assignee_id: nil,
          operations_watchdog_issue_priority: 3,
          operations_watchdog_issue_labels: ["Chore", "Observation"],
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    simulator_pool = Keyword.get(config, :simulator_pool)
    simulator_required_labels = Keyword.get(config, :simulator_required_labels)
    simulator_block_relation_type = Keyword.get(config, :simulator_block_relation_type)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    observability_issue_heartbeat_enabled = Keyword.get(config, :observability_issue_heartbeat_enabled)

    observability_issue_heartbeat_interval_ms =
      Keyword.get(config, :observability_issue_heartbeat_interval_ms)

    observability_issue_heartbeat_comment_marker =
      Keyword.get(config, :observability_issue_heartbeat_comment_marker)

    observability_issue_activity_comments_enabled =
      Keyword.get(config, :observability_issue_activity_comments_enabled)

    observability_issue_activity_comment_interval_ms =
      Keyword.get(config, :observability_issue_activity_comment_interval_ms)

    operations_disk_path = Keyword.get(config, :operations_disk_path)
    operations_disk_pause_threshold_bytes = Keyword.get(config, :operations_disk_pause_threshold_bytes)
    operations_disk_check_interval_ms = Keyword.get(config, :operations_disk_check_interval_ms)
    operations_paused_retry_interval_ms = Keyword.get(config, :operations_paused_retry_interval_ms)
    operations_cleanup_dry_run_command = Keyword.get(config, :operations_cleanup_dry_run_command)
    operations_cleanup_command = Keyword.get(config, :operations_cleanup_command)
    operations_cleanup_timeout_ms = Keyword.get(config, :operations_cleanup_timeout_ms)
    operations_cleanup_cooldown_ms = Keyword.get(config, :operations_cleanup_cooldown_ms)
    operations_paused_issue_state = Keyword.get(config, :operations_paused_issue_state)
    operations_stale_worktree_ttl_hours = Keyword.get(config, :operations_stale_worktree_ttl_hours)
    operations_stale_worktree_check_interval_ms = Keyword.get(config, :operations_stale_worktree_check_interval_ms)
    operations_stale_worktree_delete = Keyword.get(config, :operations_stale_worktree_delete)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    operations_config = %{
      disk_path: operations_disk_path,
      disk_pause_threshold_bytes: operations_disk_pause_threshold_bytes,
      disk_check_interval_ms: operations_disk_check_interval_ms,
      paused_retry_interval_ms: operations_paused_retry_interval_ms,
      cleanup_dry_run_command: operations_cleanup_dry_run_command,
      cleanup_command: operations_cleanup_command,
      cleanup_timeout_ms: operations_cleanup_timeout_ms,
      cleanup_cooldown_ms: operations_cleanup_cooldown_ms,
      paused_issue_state: operations_paused_issue_state,
      stale_worktree_ttl_hours: operations_stale_worktree_ttl_hours,
      stale_worktree_check_interval_ms: operations_stale_worktree_check_interval_ms,
      stale_worktree_delete: operations_stale_worktree_delete,
      watchdog_issue_enabled: Keyword.get(config, :operations_watchdog_issue_enabled),
      watchdog_issue_interval_ms: Keyword.get(config, :operations_watchdog_issue_interval_ms),
      watchdog_issue_title: Keyword.get(config, :operations_watchdog_issue_title),
      watchdog_issue_description: Keyword.get(config, :operations_watchdog_issue_description),
      watchdog_issue_state: Keyword.get(config, :operations_watchdog_issue_state),
      watchdog_issue_assignee_id: Keyword.get(config, :operations_watchdog_issue_assignee_id),
      watchdog_issue_priority: Keyword.get(config, :operations_watchdog_issue_priority),
      watchdog_issue_labels: Keyword.get(config, :operations_watchdog_issue_labels)
    }

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        simulators_yaml(simulator_pool, simulator_required_labels, simulator_block_relation_type),
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(
          observability_enabled,
          observability_refresh_ms,
          observability_render_interval_ms,
          observability_issue_heartbeat_enabled,
          observability_issue_heartbeat_interval_ms,
          observability_issue_heartbeat_comment_marker,
          observability_issue_activity_comments_enabled,
          observability_issue_activity_comment_interval_ms
        ),
        operations_yaml(operations_config),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp simulators_yaml(pool, required_labels, block_relation_type)
       when pool in [nil, []] and required_labels in [nil, %{}] and block_relation_type in [nil, "blocks"],
       do: nil

  defp simulators_yaml(pool, required_labels, block_relation_type) do
    [
      "simulators:",
      "  pool: #{yaml_value(pool)}",
      "  required_labels: #{yaml_value(required_labels)}",
      "  block_relation_type: #{yaml_value(block_relation_type)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(
         enabled,
         refresh_ms,
         render_interval_ms,
         issue_heartbeat_enabled,
         issue_heartbeat_interval_ms,
         issue_heartbeat_comment_marker,
         issue_activity_comments_enabled,
         issue_activity_comment_interval_ms
       ) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}",
      "  issue_heartbeat_enabled: #{yaml_value(issue_heartbeat_enabled)}",
      "  issue_heartbeat_interval_ms: #{yaml_value(issue_heartbeat_interval_ms)}",
      "  issue_heartbeat_comment_marker: #{yaml_value(issue_heartbeat_comment_marker)}",
      "  issue_activity_comments_enabled: #{yaml_value(issue_activity_comments_enabled)}",
      "  issue_activity_comment_interval_ms: #{yaml_value(issue_activity_comment_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp operations_yaml(config) do
    [
      "operations:",
      config.disk_path && "  disk_path: #{yaml_value(config.disk_path)}",
      "  disk_pause_threshold_bytes: #{yaml_value(config.disk_pause_threshold_bytes)}",
      "  disk_check_interval_ms: #{yaml_value(config.disk_check_interval_ms)}",
      "  paused_retry_interval_ms: #{yaml_value(config.paused_retry_interval_ms)}",
      config.cleanup_dry_run_command &&
        "  cleanup_dry_run_command: #{yaml_value(config.cleanup_dry_run_command)}",
      config.cleanup_command && "  cleanup_command: #{yaml_value(config.cleanup_command)}",
      "  cleanup_timeout_ms: #{yaml_value(config.cleanup_timeout_ms)}",
      "  cleanup_cooldown_ms: #{yaml_value(config.cleanup_cooldown_ms)}",
      config.paused_issue_state && "  paused_issue_state: #{yaml_value(config.paused_issue_state)}",
      "  stale_worktree_ttl_hours: #{yaml_value(config.stale_worktree_ttl_hours)}",
      "  stale_worktree_check_interval_ms: #{yaml_value(config.stale_worktree_check_interval_ms)}",
      "  stale_worktree_delete: #{yaml_value(config.stale_worktree_delete)}",
      "  watchdog_issue_enabled: #{yaml_value(config.watchdog_issue_enabled)}",
      "  watchdog_issue_interval_ms: #{yaml_value(config.watchdog_issue_interval_ms)}",
      "  watchdog_issue_title: #{yaml_value(config.watchdog_issue_title)}",
      config.watchdog_issue_description &&
        "  watchdog_issue_description: #{yaml_value(config.watchdog_issue_description)}",
      "  watchdog_issue_state: #{yaml_value(config.watchdog_issue_state)}",
      config.watchdog_issue_assignee_id &&
        "  watchdog_issue_assignee_id: #{yaml_value(config.watchdog_issue_assignee_id)}",
      "  watchdog_issue_priority: #{yaml_value(config.watchdog_issue_priority)}",
      "  watchdog_issue_labels: #{yaml_value(config.watchdog_issue_labels)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
