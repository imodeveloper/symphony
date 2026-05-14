defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
      }
    }
  }
  """

  @find_comment_query """
  query SymphonyFindIssueComment($issueId: String!, $first: Int!) {
    issue(id: $issueId) {
      comments(first: $first) {
        nodes {
          id
          body
        }
      }
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyUpdateComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body, doNotSubscribeToIssue: true}, skipEditedAt: true) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @issue_team_labels_query """
  query SymphonyIssueTeamLabels($issueId: String!, $first: Int!) {
    issue(id: $issueId) {
      team {
        id
        labels(first: $first) {
          nodes {
            id
            name
          }
        }
      }
    }
  }
  """

  @create_label_mutation """
  mutation SymphonyCreateIssueLabel($input: IssueLabelCreateInput!) {
    issueLabelCreate(input: $input) {
      success
      issueLabel {
        id
        name
      }
    }
  }
  """

  @update_labels_mutation """
  mutation SymphonyUpdateIssueLabels($issueId: String!, $input: IssueUpdateInput!) {
    issueUpdate(id: $issueId, input: $input) {
      success
    }
  }
  """

  @create_relation_mutation """
  mutation SymphonyCreateIssueRelation($input: IssueRelationCreateInput!) {
    issueRelationCreate(input: $input) {
      success
      issueRelation {
        id
      }
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec upsert_comment(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def upsert_comment(issue_id, marker, body, known_comment_id)
      when is_binary(issue_id) and is_binary(marker) and is_binary(body) do
    case normalize_comment_id(known_comment_id) do
      comment_id when is_binary(comment_id) -> update_comment(comment_id, body)
      nil -> upsert_comment_by_marker(issue_id, marker, body)
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec add_issue_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def add_issue_labels(issue_id, labels) when is_binary(issue_id) and is_list(labels) do
    case normalize_label_names(labels) do
      [] ->
        :ok

      normalized_labels ->
        with {:ok, label_ids} <- ensure_label_ids(issue_id, normalized_labels) do
          update_issue_labels(issue_id, %{addedLabelIds: label_ids})
        end
    end
  end

  @spec remove_issue_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def remove_issue_labels(issue_id, labels) when is_binary(issue_id) and is_list(labels) do
    case normalize_label_names(labels) do
      [] ->
        :ok

      normalized_labels ->
        with {:ok, label_ids} <- existing_label_ids(issue_id, normalized_labels) do
          update_issue_labels(issue_id, %{removedLabelIds: label_ids})
        end
    end
  end

  @spec create_issue_relation(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create_issue_relation(issue_id, related_issue_id, relation_type)
      when is_binary(issue_id) and is_binary(related_issue_id) and is_binary(relation_type) do
    input = %{issueId: issue_id, relatedIssueId: related_issue_id, type: relation_type}

    with {:ok, response} <- client_module().graphql(@create_relation_mutation, %{input: input}),
         true <- get_in(response, ["data", "issueRelationCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_relation_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_relation_create_failed}
    end
  end

  defp create_comment_returning_id(issue_id, body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      {:ok, get_in(response, ["data", "commentCreate", "comment", "id"])}
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  defp upsert_comment_by_marker(issue_id, marker, body) do
    case find_comment_id(issue_id, marker) do
      {:ok, comment_id} when is_binary(comment_id) -> update_comment(comment_id, body)
      {:ok, nil} -> create_comment_returning_id(issue_id, body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_comment_id(issue_id, marker) do
    with {:ok, response} <- client_module().graphql(@find_comment_query, %{issueId: issue_id, first: 50}) do
      comments = get_in(response, ["data", "issue", "comments", "nodes"]) || []

      {:ok,
       Enum.find_value(comments, fn
         %{"id" => comment_id, "body" => body} when is_binary(comment_id) and is_binary(body) ->
           if String.contains?(body, marker), do: comment_id

         _ ->
           nil
       end)}
    end
  end

  defp update_comment(comment_id, body) do
    with {:ok, response} <-
           client_module().graphql(@update_comment_mutation, %{commentId: comment_id, body: body}),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true do
      {:ok, comment_id}
    else
      false -> {:error, :comment_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_update_failed}
    end
  end

  defp normalize_comment_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      comment_id -> comment_id
    end
  end

  defp normalize_comment_id(_value), do: nil

  defp ensure_label_ids(issue_id, labels) do
    with {:ok, metadata} <- fetch_issue_team_labels(issue_id) do
      label_index = label_id_index(metadata.labels)

      labels
      |> Enum.reduce_while({:ok, []}, &ensure_label_id(&1, &2, metadata, label_index))
      |> finalize_label_ids()
    end
  end

  defp ensure_label_id(label, {:ok, ids}, metadata, label_index) do
    case Map.get(label_index, normalize_label_key(label)) do
      label_id when is_binary(label_id) -> {:cont, {:ok, [label_id | ids]}}
      nil -> create_missing_label_id(metadata.team_id, label, ids)
    end
  end

  defp create_missing_label_id(team_id, label, ids) do
    case create_label(team_id, label) do
      {:ok, label_id} -> {:cont, {:ok, [label_id | ids]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp finalize_label_ids({:ok, ids}), do: {:ok, Enum.reverse(ids)}
  defp finalize_label_ids({:error, reason}), do: {:error, reason}

  defp existing_label_ids(issue_id, labels) do
    with {:ok, metadata} <- fetch_issue_team_labels(issue_id) do
      label_index = label_id_index(metadata.labels)

      ids =
        labels
        |> Enum.map(&Map.get(label_index, normalize_label_key(&1)))
        |> Enum.reject(&is_nil/1)

      {:ok, ids}
    end
  end

  defp fetch_issue_team_labels(issue_id) do
    with {:ok, response} <- client_module().graphql(@issue_team_labels_query, %{issueId: issue_id, first: 100}),
         %{"id" => team_id, "labels" => %{"nodes" => labels}} <-
           get_in(response, ["data", "issue", "team"]) do
      {:ok, %{team_id: team_id, labels: labels}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_team_labels_not_found}
    end
  end

  defp create_label(team_id, label) do
    input = %{
      teamId: team_id,
      name: label,
      color: "#6B7280",
      description: "Symphony simulator resource label"
    }

    with {:ok, response} <- client_module().graphql(@create_label_mutation, %{input: input}),
         true <- get_in(response, ["data", "issueLabelCreate", "success"]) == true,
         label_id when is_binary(label_id) <- get_in(response, ["data", "issueLabelCreate", "issueLabel", "id"]) do
      {:ok, label_id}
    else
      false -> {:error, :issue_label_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_label_create_failed}
    end
  end

  defp update_issue_labels(_issue_id, %{removedLabelIds: []}), do: :ok

  defp update_issue_labels(issue_id, input) do
    with {:ok, response} <- client_module().graphql(@update_labels_mutation, %{issueId: issue_id, input: input}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_label_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_label_update_failed}
    end
  end

  defp label_id_index(labels) when is_list(labels) do
    Enum.reduce(labels, %{}, fn
      %{"id" => id, "name" => name}, acc when is_binary(id) and is_binary(name) ->
        Map.put(acc, normalize_label_key(name), id)

      _label, acc ->
        acc
    end)
  end

  defp normalize_label_names(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&normalize_label_key/1)
  end

  defp normalize_label_key(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
