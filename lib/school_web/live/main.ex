defmodule SchoolWeb.MainLive do
  use SchoolWeb, :live_view

  alias School.Logic
  alias School.State

  import SchoolWeb.GameComponents

  @impl true
  def mount(_params, _session, socket) do
    package = Logic.generate_package()

    Phoenix.PubSub.subscribe(School.PubSub, "game_room")

    rules_view = State.get_rules_view(nil)
    active_rules = rules_view.rules
    rule_display_rows = build_rule_display_rows(active_rules, rules_view)

    new_socket =
      socket
      |> assign(:local_player, nil)
      |> assign(:package, package)
      |> assign(:timestamp, nil)
      |> assign(:validation_result, :correct)
      |> assign(:game_state, :waiting)
      |> assign(:active_rules, active_rules)
      |> assign(:rule_display_rows, rule_display_rows)
      |> assign(:score, 0)
      |> assign(:combo_multiplier, 1)
      |> assign(:last_score_delta, 0)
      |> assign(:player_list, [])

    {:ok, new_socket}
  end

  @impl true
  def handle_event("join", %{"name" => name}, socket) do
    local_player = State.add_player(name, self())

    new_socket =
      socket
      |> assign(:local_player, local_player)

    {:noreply, new_socket}
  end

  @impl true
  def handle_event("ready", _params, socket) do
    local_player = socket.assigns.local_player
    {updated_local_player, _game_state} = State.player_ready(local_player.name)

    new_socket =
      socket
      |> assign(:local_player, updated_local_player)

    {:noreply, new_socket}
  end

  @impl true
  def handle_event("decline", _params, socket) do
    new_socket = validation("swipe-left", :invalid, socket)

    {:noreply, new_socket}
  end

  @impl true
  def handle_event("approve", _params, socket) do
    new_socket = validation("swipe-right", :valid, socket)

    {:noreply, new_socket}
  end

  @impl true
  def handle_event("add_random_rule", _params, socket) do
    new_socket = use_add_random_rule(socket)

    {:noreply, new_socket}
  end

  @impl true
  def handle_event("pause_random_rule", _params, socket) do
    new_socket = use_pause_random_rule(socket)

    {:noreply, new_socket}
  end

  @impl true
  def handle_info(:next_package, socket) do
    package = Logic.generate_package()

    new_socket =
      socket
      |> assign(:package, package)
      |> push_event("reset-package-card", %{})

    {:noreply, new_socket}
  end

  @impl true
  def handle_info({:game_start, game_state}, socket) do
    new_socket =
      socket
      |> assign(:game_state, game_state)

    {:noreply, new_socket}
  end

  @impl true
  def handle_info({:game_ended, game_state}, socket) do
    new_socket =
      socket
      |> assign(:game_state, game_state)

    {:noreply, new_socket}
  end

  @impl true
  def handle_info({:tick_update, current_game_time}, socket) do
    width = build_game_time_loading_bar(current_game_time)

    refreshed_socket = refresh_rule_display(socket)

    new_socket =
      refreshed_socket
      |> push_event("timer-tick", %{time: current_game_time, width: width})

    {:noreply, new_socket}
  end

  @impl true
  def handle_info(:update_rules, socket) do
    {:noreply, refresh_rule_display(socket)}
  end

  def handle_info({:update_player_list, updated_player_list}, socket) do
    new_socket =
      socket
      |> assign(:player_list, updated_player_list)

    {:noreply, new_socket}
  end

  defp validation(swipe_direction, expected, socket) do
    package = socket.assigns.package

    {updated_player, decision, validation_msg, score_delta} =
      State.update_player_score(self(), package, expected)

    new_socket =
      socket
      |> assign(:validation_result, decision)
      |> assign(:validation_msg, validation_msg)
      |> assign(:local_player, updated_player)
      |> assign(:score, updated_player.score)
      |> assign(:combo_multiplier, updated_player.combo_multiplier)
      |> assign(:last_score_delta, score_delta)
      |> push_event(swipe_direction, %{})

    Process.send_after(self(), :next_package, 1_000)

    new_socket
  end

  def build_game_time_loading_bar(game_time) do
    max_game_time = State.max_game_time()
    game_time / max_game_time * 100
  end

  defp use_add_random_rule(socket) do
    case State.induce_random_rule(self()) do
      {:ok, updated_player} ->
        socket
        |> assign(:local_player, updated_player)
        |> assign(:score, updated_player.score)
        |> assign(:combo_multiplier, updated_player.combo_multiplier)
        |> refresh_rule_display()

      _ ->
        socket
    end
  end

  defp use_pause_random_rule(socket) do
    case State.pause_random_rule(self()) do
      {:ok, updated_player} ->
        socket
        |> assign(:local_player, updated_player)
        |> assign(:score, updated_player.score)
        |> assign(:combo_multiplier, updated_player.combo_multiplier)
        |> refresh_rule_display()

      _ ->
        socket
    end
  end

  defp refresh_rule_display(socket) do
    pid =
      case socket.assigns.local_player do
        nil -> nil
        player -> player.pid
      end

    rules_view = State.get_rules_view(pid)
    active_rules = rules_view.rules

    socket
    |> assign(:active_rules, active_rules)
    |> assign(:rule_display_rows, build_rule_display_rows(active_rules, rules_view))
  end

  defp build_rule_display_rows(active_rules, rules_view) do
    Enum.map(active_rules, fn rule ->
      %{
        description: Logic.description_by_rule(rule),
        added?: rule == rules_view.added_rule,
        paused?: rule == rules_view.paused_rule,
        added_seconds_left: if(rule == rules_view.added_rule, do: rules_view.added_seconds_left, else: 0),
        paused_seconds_left:
          if(rule == rules_view.paused_rule, do: rules_view.paused_seconds_left, else: 0)
      }
    end)
  end
end
