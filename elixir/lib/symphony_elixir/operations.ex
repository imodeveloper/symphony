defmodule SymphonyElixir.Operations do
  @moduledoc """
  Runtime operations guardrails for disk pressure and workspace hygiene.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Linear.{Client, Issue}

  @project_lookup_query """
  query SymphonyWatchdogProject($slug: String!) {
    projects(filter: {slugId: {eq: $slug}}, first: 1) {
      nodes {
        id
        teams(first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @team_metadata_query """
  query SymphonyWatchdogTeam($teamId: String!) {
    team(id: $teamId) {
      states(first: 50) {
        nodes {
          id
          name
        }
      }
      labels(first: 50) {
        nodes {
          id
          name
        }
      }
    }
  }
  """

  @issue_search_query """
  query SymphonyWatchdogIssue($projectId: ID!, $title: String!) {
    issues(filter: {project: {id: {eq: $projectId}}, title: {containsIgnoreCase: $title}}, first: 20) {
      nodes {
        id
        identifier
        title
        url
        priority
        state {
          name
        }
      }
    }
  }
  """

  @issue_create_mutation """
  mutation SymphonyCreateWatchdogIssue($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        title
        url
        state {
          name
        }
      }
    }
  }
  """

  @issue_update_mutation """
  mutation SymphonyPulseWatchdogIssue($issueId: String!, $input: IssueUpdateInput!) {
    issueUpdate(id: $issueId, input: $input) {
      success
      issue {
        id
        identifier
        title
        url
        state {
          name
        }
      }
    }
  }
  """

  @default_snapshot %{
    heartbeat_at: nil,
    dispatch: %{
      paused?: false,
      reason: nil,
      paused_issue_state: nil,
      unresolved_after_cleanup?: false
    },
    disk: %{
      status: "unknown",
      path: nil,
      available_bytes: nil,
      total_bytes: nil,
      used_percent: nil,
      threshold_bytes: nil,
      checked_at: nil,
      error: nil
    },
    cleanup: %{
      status: "idle",
      started_at: nil,
      finished_at: nil,
      exit_status: nil,
      output: nil,
      error: nil
    },
    stale_worktrees: %{
      status: "idle",
      checked_at: nil,
      root: nil,
      ttl_hours: nil,
      scanned: 0,
      deleted: [],
      skipped_active: [],
      errors: []
    },
    linear_watchdog: %{
      status: "disabled",
      checked_at: nil,
      issue_identifier: nil,
      issue_url: nil,
      action: nil,
      next_check_interval_ms: nil,
      error: nil
    }
  }

  defmodule State do
    @moduledoc false

    defstruct [
      :disk_timer_ref,
      :stale_timer_ref,
      :watchdog_timer_ref,
      :cleanup_task_ref,
      :cleanup_task_pid,
      :last_cleanup_started_at_ms,
      :disk_usage_fun,
      :command_runner,
      :auto_schedule?,
      snapshot: nil
    ]
  end

  @type dispatch_pause :: %{
          paused?: boolean(),
          reason: String.t() | nil,
          paused_issue_state: String.t() | nil,
          unresolved_after_cleanup?: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    if server_available?(server) do
      GenServer.call(server, :snapshot, 5_000)
    else
      @default_snapshot
    end
  catch
    :exit, _reason -> @default_snapshot
  end

  @spec dispatch_pause(GenServer.server()) :: dispatch_pause()
  def dispatch_pause(server \\ __MODULE__) do
    server
    |> snapshot()
    |> Map.get(:dispatch, @default_snapshot.dispatch)
  end

  @doc false
  @spec disk_usage(Path.t()) :: {:ok, map()} | {:error, term()}
  def disk_usage(path) when is_binary(path) do
    case System.cmd("df", ["-k", path], stderr_to_stdout: true) do
      {output, 0} -> parse_df_output(output, path)
      {output, status} -> {:error, {:df_failed, status, String.trim(output)}}
    end
  rescue
    error in [ErlangError, RuntimeError] -> {:error, error}
  end

  @doc false
  @spec parse_df_output(String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def parse_df_output(output, path) when is_binary(output) and is_binary(path) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> List.last()
    |> case do
      nil ->
        {:error, :df_output_missing_usage_line}

      line ->
        fields = String.split(line, ~r/\s+/, trim: true)

        with blocks when is_binary(blocks) <- Enum.at(fields, 1),
             available when is_binary(available) <- Enum.at(fields, 3),
             capacity when is_binary(capacity) <- Enum.at(fields, 4),
             {block_count, ""} <- Integer.parse(blocks),
             {available_count, ""} <- Integer.parse(available) do
          {:ok,
           %{
             path: path,
             total_bytes: block_count * 1024,
             available_bytes: available_count * 1024,
             used_percent: parse_percent(capacity)
           }}
        else
          _ -> {:error, {:df_output_unrecognized, line}}
        end
    end
  end

  @impl true
  def init(opts) do
    state = %State{
      disk_usage_fun: Keyword.get(opts, :disk_usage_fun, &disk_usage/1),
      command_runner: Keyword.get(opts, :command_runner, &run_shell_command/2),
      auto_schedule?: Keyword.get(opts, :auto_schedule?, true),
      snapshot: @default_snapshot
    }

    state =
      if state.auto_schedule? do
        state
        |> schedule_disk_check(0)
        |> schedule_stale_worktree_check(1_000)
        |> schedule_watchdog_issue_check(2_000)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply, state.snapshot, state}
  end

  @impl true
  def handle_info(:check_disk, %State{} = state) do
    state =
      state
      |> Map.put(:disk_timer_ref, nil)
      |> check_disk()
      |> maybe_schedule_next_disk_check()

    StatusDashboard.notify_update()
    {:noreply, state}
  end

  def handle_info(:check_stale_worktrees, %State{} = state) do
    state =
      state
      |> Map.put(:stale_timer_ref, nil)
      |> cleanup_stale_worktrees()
      |> maybe_schedule_next_stale_worktree_check()

    StatusDashboard.notify_update()
    {:noreply, state}
  end

  def handle_info(:ensure_watchdog_issue, %State{} = state) do
    state =
      state
      |> Map.put(:watchdog_timer_ref, nil)
      |> ensure_watchdog_issue()
      |> maybe_schedule_next_watchdog_issue_check()

    StatusDashboard.notify_update()
    {:noreply, state}
  end

  def handle_info({_ref, {:cleanup_finished, result}}, %State{} = state) do
    state =
      state
      |> clear_cleanup_task()
      |> put_cleanup_result(result)
      |> check_disk()
      |> maybe_schedule_next_disk_check()

    StatusDashboard.notify_update()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{cleanup_task_ref: ref} = state) do
    state =
      state
      |> clear_cleanup_task()
      |> put_cleanup_result({:error, {:cleanup_task_down, reason}})
      |> check_disk()
      |> maybe_schedule_next_disk_check()

    StatusDashboard.notify_update()
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %State{} = state), do: {:noreply, state}

  defp check_disk(%State{} = state) do
    case Config.settings() do
      {:ok, settings} ->
        check_disk_with_settings(state, settings)

      {:error, reason} ->
        put_config_error(state, reason)
    end
  end

  defp check_disk_with_settings(%State{} = state, settings) do
    operations = settings.operations
    path = operations.disk_path
    threshold_bytes = operations.disk_pause_threshold_bytes
    checked_at = timestamp()

    case state.disk_usage_fun.(path) do
      {:ok, usage} ->
        low_disk? = usage.available_bytes < threshold_bytes

        state
        |> put_disk_usage(usage, threshold_bytes, checked_at, low_disk?)
        |> maybe_start_cleanup(settings, low_disk?)

      {:error, reason} ->
        put_disk_error(state, path, threshold_bytes, checked_at, reason)
    end
  end

  defp maybe_start_cleanup(%State{cleanup_task_ref: ref} = state, _settings, true)
       when is_reference(ref) do
    put_dispatch_status(state, true, "disk cleanup is running")
  end

  defp maybe_start_cleanup(%State{} = state, settings, true) do
    operations = settings.operations

    cond do
      String.trim(to_string(operations.cleanup_command || "")) == "" ->
        put_dispatch_status(state, true, "disk free space is below threshold")

      cleanup_in_cooldown?(state, operations.cleanup_cooldown_ms) ->
        put_dispatch_status(state, true, "disk free space is below threshold; cleanup is in cooldown")

      true ->
        start_cleanup(state, operations)
    end
  end

  defp maybe_start_cleanup(%State{} = state, settings, false) do
    state
    |> put_dispatch_status(false, nil, settings.operations.paused_issue_state)
    |> maybe_reset_cleanup_after_recovery()
  end

  defp start_cleanup(%State{} = state, operations) do
    started_at = timestamp()
    started_at_ms = System.monotonic_time(:millisecond)
    dry_run_command = blank_to_nil(operations.cleanup_dry_run_command)
    cleanup_command = blank_to_nil(operations.cleanup_command)
    timeout_ms = operations.cleanup_timeout_ms
    command_runner = state.command_runner

    task =
      Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        run_cleanup_sequence(dry_run_command, cleanup_command, timeout_ms, command_runner)
      end)

    cleanup = %{
      status: "running",
      started_at: started_at,
      finished_at: nil,
      exit_status: nil,
      output: nil,
      error: nil
    }

    %{
      state
      | cleanup_task_ref: task.ref,
        cleanup_task_pid: task.pid,
        last_cleanup_started_at_ms: started_at_ms,
        snapshot:
          state.snapshot
          |> put_in([:cleanup], cleanup)
          |> put_in([:dispatch], %{
            paused?: true,
            reason: "disk free space is below threshold; cleanup is running",
            paused_issue_state: operations.paused_issue_state,
            unresolved_after_cleanup?: false
          })
    }
  rescue
    error in [ArgumentError, RuntimeError] ->
      state
      |> put_cleanup_result({:error, error})
      |> put_dispatch_status(true, "disk free space is below threshold; cleanup failed", operations.paused_issue_state)
  end

  defp run_cleanup_sequence(dry_run_command, cleanup_command, timeout_ms, command_runner) do
    commands =
      [
        {"dry_run", dry_run_command},
        {"cleanup", cleanup_command}
      ]
      |> Enum.reject(fn {_name, command} -> is_nil(command) end)

    results =
      Enum.map(commands, fn {name, command} ->
        {status, output} = command_runner.(command, timeout_ms)
        %{name: name, command: command, status: status, output: output}
      end)

    exit_status =
      results
      |> Enum.map(& &1.status)
      |> Enum.find(0, &(&1 != 0))

    output =
      results
      |> Enum.map_join("\n\n", fn result ->
        "$ #{result.command}\n#{result.output}"
      end)

    {:cleanup_finished, %{status: exit_status, output: output}}
  end

  defp run_shell_command(command, timeout_ms) when is_binary(command) and is_integer(timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {output, status}} ->
        {status, output}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {124, "Command timed out after #{timeout_ms}ms"}
    end
  end

  defp cleanup_stale_worktrees(%State{} = state) do
    case Config.settings() do
      {:ok, settings} ->
        cleanup_stale_worktrees_with_settings(state, settings)

      {:error, reason} ->
        put_stale_worktree_error(state, nil, nil, reason)
    end
  end

  defp ensure_watchdog_issue(%State{} = state) do
    case Config.settings() do
      {:ok, %{tracker: %{kind: "linear"}} = settings} ->
        ensure_watchdog_issue_with_settings(state, settings)

      {:ok, _settings} ->
        put_linear_watchdog_snapshot(state, %{status: "disabled", action: "tracker_not_linear"})

      {:error, reason} ->
        put_linear_watchdog_snapshot(state, %{status: "error", error: inspect(reason)})
    end
  end

  defp ensure_watchdog_issue_with_settings(%State{} = state, settings) do
    operations = settings.operations

    if operations.watchdog_issue_enabled == true do
      settings
      |> ensure_linear_watchdog_issue()
      |> put_linear_watchdog_result(state, operations)
    else
      put_linear_watchdog_snapshot(state, %{
        status: "disabled",
        action: "disabled",
        next_check_interval_ms: operations.watchdog_issue_interval_ms
      })
    end
  end

  defp ensure_linear_watchdog_issue(settings) do
    operations = settings.operations

    with {:ok, context} <- linear_watchdog_context(settings),
         {:ok, issue} <- find_watchdog_issue(context.project_id, operations.watchdog_issue_title) do
      active_states = normalized_state_set(settings.tracker.active_states)
      handle_watchdog_issue(issue, context, operations, active_states)
    end
  end

  defp handle_watchdog_issue(nil, context, operations, _active_states) do
    create_watchdog_issue(context, operations)
  end

  defp handle_watchdog_issue(%{state: state_name} = issue, context, operations, active_states)
       when is_binary(state_name) do
    if MapSet.member?(active_states, normalize_state(state_name)) do
      refresh_watchdog_issue_metadata(issue, context, operations)
    else
      pulse_watchdog_issue(issue, context, operations)
    end
  end

  defp handle_watchdog_issue(issue, context, operations, _active_states) do
    pulse_watchdog_issue(issue, context, operations)
  end

  defp linear_watchdog_context(settings) do
    with {:ok, project} <- fetch_watchdog_project(settings.tracker.project_slug),
         {:ok, metadata} <- fetch_watchdog_team_metadata(project.team_id),
         {:ok, target_state_id} <- find_named_id(metadata.states, settings.operations.watchdog_issue_state),
         {:ok, label_ids} <- find_label_ids(metadata.labels, settings.operations.watchdog_issue_labels) do
      {:ok,
       %{
         project_id: project.project_id,
         team_id: project.team_id,
         target_state_id: target_state_id,
         label_ids: label_ids
       }}
    end
  end

  defp fetch_watchdog_project(project_slug) when is_binary(project_slug) do
    with {:ok, response} <- linear_client_module().graphql(@project_lookup_query, %{slug: project_slug}),
         %{"id" => project_id, "teams" => %{"nodes" => [%{"id" => team_id} | _]}} <-
           get_in(response, ["data", "projects", "nodes", Access.at(0)]) do
      {:ok, %{project_id: project_id, team_id: team_id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :watchdog_project_not_found}
    end
  end

  defp fetch_watchdog_project(_project_slug), do: {:error, :missing_linear_project_slug}

  defp fetch_watchdog_team_metadata(team_id) when is_binary(team_id) do
    with {:ok, response} <- linear_client_module().graphql(@team_metadata_query, %{teamId: team_id}),
         %{"states" => %{"nodes" => states}, "labels" => %{"nodes" => labels}} <-
           get_in(response, ["data", "team"]) do
      {:ok, %{states: states, labels: labels}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :watchdog_team_metadata_not_found}
    end
  end

  defp find_watchdog_issue(project_id, title) when is_binary(project_id) and is_binary(title) do
    with {:ok, response} <-
           linear_client_module().graphql(@issue_search_query, %{projectId: project_id, title: title}) do
      issue =
        response
        |> get_in(["data", "issues", "nodes"])
        |> List.wrap()
        |> Enum.find(&(Map.get(&1, "title") == title))
        |> normalize_watchdog_issue()

      {:ok, issue}
    end
  end

  defp create_watchdog_issue(context, operations) do
    input =
      %{
        teamId: context.team_id,
        projectId: context.project_id,
        stateId: context.target_state_id,
        title: operations.watchdog_issue_title,
        description: watchdog_issue_description(operations),
        priority: operations.watchdog_issue_priority,
        labelIds: context.label_ids
      }
      |> maybe_put(:assigneeId, blank_to_nil(operations.watchdog_issue_assignee_id))

    with {:ok, response} <- linear_client_module().graphql(@issue_create_mutation, %{input: input}),
         true <- get_in(response, ["data", "issueCreate", "success"]) == true,
         %{} = issue <- get_in(response, ["data", "issueCreate", "issue"]) do
      {:ok, :created, normalize_watchdog_issue(issue)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :watchdog_issue_create_failed}
    end
  end

  defp refresh_watchdog_issue_metadata(issue, context, operations) do
    with {:ok, issue} <- update_watchdog_issue(issue.id, watchdog_issue_metadata_input(context, operations)) do
      {:ok, :already_active, issue}
    end
  end

  defp pulse_watchdog_issue(issue, context, operations) do
    input =
      context
      |> watchdog_issue_metadata_input(operations)
      |> Map.put(:stateId, context.target_state_id)

    with {:ok, issue} <- update_watchdog_issue(issue.id, input) do
      {:ok, :pulsed, issue}
    end
  end

  defp update_watchdog_issue(issue_id, input) do
    with {:ok, response} <-
           linear_client_module().graphql(@issue_update_mutation, %{issueId: issue_id, input: input}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true,
         %{} = updated_issue <- get_in(response, ["data", "issueUpdate", "issue"]) do
      {:ok, normalize_watchdog_issue(updated_issue)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :watchdog_issue_update_failed}
    end
  end

  defp watchdog_issue_metadata_input(_context, operations) do
    %{
      description: watchdog_issue_description(operations),
      priority: operations.watchdog_issue_priority
    }
    |> maybe_put(:assigneeId, blank_to_nil(operations.watchdog_issue_assignee_id))
  end

  defp find_named_id(nodes, name) when is_list(nodes) and is_binary(name) do
    nodes
    |> Enum.find(fn node -> normalize_state(Map.get(node, "name")) == normalize_state(name) end)
    |> case do
      %{"id" => id} when is_binary(id) -> {:ok, id}
      _ -> {:error, {:watchdog_name_not_found, name}}
    end
  end

  defp find_label_ids(nodes, labels) when is_list(nodes) and is_list(labels) do
    labels
    |> Enum.map(&find_named_id(nodes, &1))
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, id}, {:ok, ids} -> {:cont, {:ok, [id | ids]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_linear_watchdog_result({:ok, action, issue}, state, operations) do
    put_linear_watchdog_snapshot(state, %{
      status: "ready",
      issue_identifier: Map.get(issue, :identifier),
      issue_url: Map.get(issue, :url),
      action: to_string(action),
      next_check_interval_ms: operations.watchdog_issue_interval_ms
    })
  end

  defp put_linear_watchdog_result({:error, reason}, state, operations) do
    put_linear_watchdog_snapshot(state, %{
      status: "error",
      action: "failed",
      next_check_interval_ms: operations.watchdog_issue_interval_ms,
      error: inspect(reason)
    })
  end

  defp put_linear_watchdog_snapshot(%State{} = state, attrs) do
    snapshot =
      @default_snapshot.linear_watchdog
      |> Map.merge(Map.put(attrs, :checked_at, timestamp()))

    %{state | snapshot: put_in(state.snapshot, [:linear_watchdog], snapshot)}
  end

  defp cleanup_stale_worktrees_with_settings(%State{} = state, settings) do
    operations = settings.operations
    root = settings.workspace.root
    ttl_hours = operations.stale_worktree_ttl_hours

    cond do
      operations.stale_worktree_delete != true ->
        put_stale_worktree_snapshot(state, root, ttl_hours, "disabled", [], [], [], [])

      !is_integer(ttl_hours) or ttl_hours <= 0 ->
        put_stale_worktree_snapshot(state, root, ttl_hours, "disabled", [], [], [], [])

      !File.dir?(root) ->
        put_stale_worktree_snapshot(state, root, ttl_hours, "missing_root", [], [], [], [])

      true ->
        do_cleanup_stale_worktrees(state, settings, root, ttl_hours)
    end
  end

  defp do_cleanup_stale_worktrees(%State{} = state, settings, root, ttl_hours) do
    case active_worktree_identifiers(settings) do
      {:ok, active_identifiers} ->
        cutoff_ms = System.system_time(:millisecond) - ttl_hours * 60 * 60 * 1_000
        entries = workspace_entries(root)

        {deleted, skipped, errors} =
          Enum.reduce(entries, {[], [], []}, fn path, acc ->
            path
            |> stale_worktree_action(active_identifiers, cutoff_ms)
            |> collect_stale_worktree_action(acc)
          end)

        put_stale_worktree_snapshot(
          state,
          root,
          ttl_hours,
          "checked",
          entries,
          Enum.reverse(deleted),
          Enum.reverse(skipped),
          Enum.reverse(errors)
        )

      {:error, reason} ->
        put_stale_worktree_error(state, root, ttl_hours, reason)
    end
  end

  defp stale_worktree_action(path, active_identifiers, cutoff_ms) do
    identifier = Path.basename(path)

    cond do
      MapSet.member?(active_identifiers, identifier) ->
        {:skip, identifier}

      stale_worktree?(path, cutoff_ms) ->
        remove_stale_worktree(path, identifier)

      true ->
        :keep
    end
  end

  defp remove_stale_worktree(path, identifier) do
    case Workspace.remove(path) do
      {:ok, _removed} ->
        {:delete, identifier}

      {:error, reason, output} ->
        {:error, %{identifier: identifier, reason: inspect(reason), output: output}}
    end
  end

  defp collect_stale_worktree_action({:delete, identifier}, {deleted, skipped, errors}) do
    {[identifier | deleted], skipped, errors}
  end

  defp collect_stale_worktree_action({:skip, identifier}, {deleted, skipped, errors}) do
    {deleted, [identifier | skipped], errors}
  end

  defp collect_stale_worktree_action({:error, error}, {deleted, skipped, errors}) do
    {deleted, skipped, [error | errors]}
  end

  defp collect_stale_worktree_action(:keep, acc), do: acc

  defp active_worktree_identifiers(settings) do
    case Tracker.fetch_issues_by_states(settings.tracker.active_states) do
      {:ok, issues} ->
        identifiers =
          issues
          |> Enum.flat_map(fn
            %Issue{identifier: identifier} when is_binary(identifier) -> [identifier]
            _ -> []
          end)
          |> MapSet.new()

        {:ok, identifiers}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_entries(root) when is_binary(root) do
    root
    |> File.ls!()
    |> Enum.map(&Path.join(root, &1))
    |> Enum.filter(&File.dir?/1)
  rescue
    _error in [File.Error] -> []
  end

  defp stale_worktree?(path, cutoff_ms) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} when is_integer(mtime) ->
        mtime * 1_000 < cutoff_ms

      _ ->
        false
    end
  end

  defp put_disk_usage(%State{} = state, usage, threshold_bytes, checked_at, low_disk?) do
    disk = %{
      status: if(low_disk?, do: "low", else: "healthy"),
      path: usage.path,
      available_bytes: usage.available_bytes,
      total_bytes: usage.total_bytes,
      used_percent: usage.used_percent,
      threshold_bytes: threshold_bytes,
      checked_at: checked_at,
      error: nil
    }

    %{state | snapshot: state.snapshot |> put_in([:heartbeat_at], checked_at) |> put_in([:disk], disk)}
  end

  defp put_disk_error(%State{} = state, path, threshold_bytes, checked_at, reason) do
    disk = %{
      status: "error",
      path: path,
      available_bytes: nil,
      total_bytes: nil,
      used_percent: nil,
      threshold_bytes: threshold_bytes,
      checked_at: checked_at,
      error: inspect(reason)
    }

    state
    |> Map.put(:snapshot, state.snapshot |> put_in([:heartbeat_at], checked_at) |> put_in([:disk], disk))
    |> put_dispatch_status(true, "disk check failed")
  end

  defp put_config_error(%State{} = state, reason) do
    checked_at = timestamp()

    disk = %{
      status: "error",
      path: nil,
      available_bytes: nil,
      total_bytes: nil,
      used_percent: nil,
      threshold_bytes: nil,
      checked_at: checked_at,
      error: inspect(reason)
    }

    state
    |> Map.put(:snapshot, state.snapshot |> put_in([:heartbeat_at], checked_at) |> put_in([:disk], disk))
    |> put_dispatch_status(true, "operations config failed")
  end

  defp put_dispatch_status(%State{} = state, paused?, reason, paused_issue_state \\ nil) do
    unresolved_after_cleanup? =
      paused? and get_in(state.snapshot, [:cleanup, :status]) in ["completed", "failed"]

    dispatch = %{
      paused?: paused?,
      reason: reason,
      paused_issue_state: paused_issue_state,
      unresolved_after_cleanup?: unresolved_after_cleanup?
    }

    %{state | snapshot: put_in(state.snapshot, [:dispatch], dispatch)}
  end

  defp put_cleanup_result(%State{} = state, {:cleanup_finished, %{status: status, output: output}}) do
    cleanup = %{
      status: if(status == 0, do: "completed", else: "failed"),
      started_at: get_in(state.snapshot, [:cleanup, :started_at]),
      finished_at: timestamp(),
      exit_status: status,
      output: truncate_output(output),
      error: nil
    }

    %{state | snapshot: put_in(state.snapshot, [:cleanup], cleanup)}
  end

  defp put_cleanup_result(%State{} = state, {:error, reason}) do
    cleanup = %{
      status: "failed",
      started_at: get_in(state.snapshot, [:cleanup, :started_at]),
      finished_at: timestamp(),
      exit_status: nil,
      output: nil,
      error: inspect(reason)
    }

    %{state | snapshot: put_in(state.snapshot, [:cleanup], cleanup)}
  end

  defp put_stale_worktree_snapshot(state, root, ttl_hours, status, scanned, deleted, skipped, errors) do
    stale_worktrees = %{
      status: status,
      checked_at: timestamp(),
      root: root,
      ttl_hours: ttl_hours,
      scanned: length(scanned),
      deleted: deleted,
      skipped_active: skipped,
      errors: errors
    }

    %{state | snapshot: put_in(state.snapshot, [:stale_worktrees], stale_worktrees)}
  end

  defp put_stale_worktree_error(state, root, ttl_hours, reason) do
    put_stale_worktree_snapshot(state, root, ttl_hours, "error", [], [], [], [inspect(reason)])
  end

  defp maybe_reset_cleanup_after_recovery(%State{} = state) do
    case get_in(state.snapshot, [:cleanup, :status]) do
      status when status in ["completed", "failed"] ->
        cleanup = %{
          status: "idle",
          started_at: get_in(state.snapshot, [:cleanup, :started_at]),
          finished_at: get_in(state.snapshot, [:cleanup, :finished_at]),
          exit_status: get_in(state.snapshot, [:cleanup, :exit_status]),
          output: get_in(state.snapshot, [:cleanup, :output]),
          error: get_in(state.snapshot, [:cleanup, :error])
        }

        %{state | snapshot: put_in(state.snapshot, [:cleanup], cleanup)}

      _ ->
        state
    end
  end

  defp clear_cleanup_task(%State{} = state) do
    %{state | cleanup_task_ref: nil, cleanup_task_pid: nil}
  end

  defp cleanup_in_cooldown?(%State{last_cleanup_started_at_ms: nil}, _cooldown_ms), do: false

  defp cleanup_in_cooldown?(%State{last_cleanup_started_at_ms: started_at_ms}, cooldown_ms)
       when is_integer(started_at_ms) and is_integer(cooldown_ms) do
    System.monotonic_time(:millisecond) - started_at_ms < cooldown_ms
  end

  defp cleanup_in_cooldown?(_state, _cooldown_ms), do: false

  defp maybe_schedule_next_disk_check(%State{auto_schedule?: true} = state) do
    case Config.settings() do
      {:ok, settings} -> schedule_disk_check(state, settings.operations.disk_check_interval_ms)
      {:error, _reason} -> schedule_disk_check(state, 60_000)
    end
  end

  defp maybe_schedule_next_disk_check(%State{} = state), do: state

  defp maybe_schedule_next_stale_worktree_check(%State{auto_schedule?: true} = state) do
    case Config.settings() do
      {:ok, settings} -> schedule_stale_worktree_check(state, settings.operations.stale_worktree_check_interval_ms)
      {:error, _reason} -> schedule_stale_worktree_check(state, 3_600_000)
    end
  end

  defp maybe_schedule_next_stale_worktree_check(%State{} = state), do: state

  defp maybe_schedule_next_watchdog_issue_check(%State{auto_schedule?: true} = state) do
    case Config.settings() do
      {:ok, settings} -> schedule_watchdog_issue_check(state, settings.operations.watchdog_issue_interval_ms)
      {:error, _reason} -> schedule_watchdog_issue_check(state, 3_600_000)
    end
  end

  defp maybe_schedule_next_watchdog_issue_check(%State{} = state), do: state

  defp schedule_disk_check(%State{disk_timer_ref: ref} = state, _delay_ms) when is_reference(ref), do: state

  defp schedule_disk_check(%State{} = state, delay_ms) do
    %{state | disk_timer_ref: Process.send_after(self(), :check_disk, max(delay_ms, 0))}
  end

  defp schedule_stale_worktree_check(%State{stale_timer_ref: ref} = state, _delay_ms) when is_reference(ref),
    do: state

  defp schedule_stale_worktree_check(%State{} = state, delay_ms) do
    %{state | stale_timer_ref: Process.send_after(self(), :check_stale_worktrees, max(delay_ms, 0))}
  end

  defp schedule_watchdog_issue_check(%State{watchdog_timer_ref: ref} = state, _delay_ms)
       when is_reference(ref),
       do: state

  defp schedule_watchdog_issue_check(%State{} = state, delay_ms) do
    %{state | watchdog_timer_ref: Process.send_after(self(), :ensure_watchdog_issue, max(delay_ms, 0))}
  end

  defp server_available?(server) when is_atom(server), do: Process.whereis(server) != nil
  defp server_available?(server) when is_pid(server), do: Process.alive?(server)
  defp server_available?(_server), do: true

  defp parse_percent(value) when is_binary(value) do
    value
    |> String.trim_trailing("%")
    |> Integer.parse()
    |> case do
      {percent, ""} -> percent
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_watchdog_issue(nil), do: nil

  defp normalize_watchdog_issue(issue) when is_map(issue) do
    %{
      id: Map.get(issue, "id"),
      identifier: Map.get(issue, "identifier"),
      title: Map.get(issue, "title"),
      url: Map.get(issue, "url"),
      state: get_in(issue, ["state", "name"])
    }
  end

  defp normalized_state_set(states) when is_list(states) do
    states
    |> Enum.map(&normalize_state/1)
    |> MapSet.new()
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp watchdog_issue_description(%{watchdog_issue_description: description}) when is_binary(description) do
    description
  end

  defp watchdog_issue_description(_operations) do
    """
    Scheduled by Symphony. Run exactly one Monitor watchdog cycle for the dedicated simulator, update the Codex Workpad, then move this issue to Done. Symphony will move this same issue back to Todo on the next hourly interval when it is not already active.
    """
  end

  defp linear_client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp truncate_output(output, max_bytes \\ 8_000)

  defp truncate_output(output, max_bytes) when is_binary(output) do
    if byte_size(output) <= max_bytes do
      output
    else
      binary_part(output, 0, max_bytes) <> "\n... (truncated)"
    end
  end

  defp truncate_output(output, max_bytes), do: truncate_output(inspect(output), max_bytes)
end
