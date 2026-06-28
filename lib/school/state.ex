defmodule School.State do
  use GenServer

  alias School.Player
  alias School.Logic

  @max_active_rules 5
  @available_rules [
    :rule1,
    :rule2,
    :rule3,
    :rule4,
    :rule5,
    :rule6,
    :rule7,
    :rule8,
    :rule9,
    :rule10
  ]
  @max_game_time_seconds 240
  @effect_duration_ms 10_000
  @combo_window_ms 1_500
  @base_correct_points 2
  @base_incorrect_points -2
  @max_combo_multiplier 3
  @add_random_rule_cost 2
  @pause_random_rule_cost 4

  defstruct active_rules: [],
            players: [],
            current_game_time: 0,
            induced_rule: nil,
            induced_rule_expires_at_ms: nil,
            paused_rules_by_pid: %{}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  def add_player(name, pid) do
    GenServer.call(__MODULE__, {:add_player, name, pid})
  end

  def player_ready(name) do
    GenServer.call(__MODULE__, {:player_ready, name})
  end

  @spec set_random_rule() :: :ok
  def set_random_rule do
    GenServer.cast(__MODULE__, :set_random_rule)
  end

  def get_active_rules do
    GenServer.call(__MODULE__, :get_active_rules)
  end

  def update_player_score(pid, package, expected) do
    GenServer.call(__MODULE__, {:update_player_score, pid, package, expected})
  end

  def induce_random_rule(pid) do
    GenServer.call(__MODULE__, {:induce_random_rule, pid})
  end

  def pause_random_rule(pid) do
    GenServer.call(__MODULE__, {:pause_random_rule, pid})
  end

  def get_rules_view(pid) do
    GenServer.call(__MODULE__, {:get_rules_view, pid})
  end

  @impl true
  def handle_call({:player_ready, name}, _from, state) do
    {[player], remaining_players} =
      Enum.split_with(state.players, fn player -> player.name == name end)

    readied_player = Map.put(player, :ready?, true)
    updated_player_list = [readied_player | remaining_players]
    game_state = maybe_start_game(updated_player_list)

    new_state =
      state
      |> Map.put(:players, updated_player_list)
      |> Map.put(:game_state, game_state)

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:update_player_list, sort_by_score(updated_player_list)}
    )

    {:reply, {readied_player, game_state}, new_state}
  end

  @impl true
  def handle_call(:get_active_rules, _from, state) do
    {:reply, current_global_rules(state), state}
  end

  @impl true
  def handle_call({:get_rules_view, pid}, _from, state) do
    now_ms = now_ms()
    paused_effect = paused_effect_for_pid(state, pid)

    reply = %{
      rules: current_global_rules(state),
      added_rule: state.induced_rule,
      added_seconds_left: seconds_left(state.induced_rule_expires_at_ms, now_ms),
      paused_rule: paused_rule(paused_effect),
      paused_seconds_left: paused_seconds_left(paused_effect, now_ms)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:update_player_score, pid, package, expected}, _from, state) do
    {[player], remaining_players} =
      Enum.split_with(state.players, fn player -> player.pid == pid end)

    effective_rules = active_rules_for_player(state, pid)

    {validation_result, validation_msg} =
      Logic.validate(package, effective_rules)

    decision =
      if validation_result == expected,
        do: :correct,
        else: :incorrect

    {combo_updated_player, score_delta} =
      combo_scored_player(player, decision)

    new_score = max(combo_updated_player.score + score_delta, 0)

    updated_player = Map.put(combo_updated_player, :score, new_score)

    updated_player_list = [updated_player | remaining_players]

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:update_player_list, sort_by_score(updated_player_list)}
    )

    new_state = Map.put(state, :players, updated_player_list)

    {:reply, {updated_player, decision, validation_msg, score_delta}, new_state}
  end

  @impl true
  def handle_call({:induce_random_rule, pid}, _from, state) do
    case find_player_by_pid(state.players, pid) do
      nil ->
        {:reply, {:error, :player_not_found}, state}

      player ->
        if enough_score?(player, @add_random_rule_cost) do
          updated_player = apply_score_cost(player, @add_random_rule_cost)
          state_with_updated_player = put_player(state, updated_player)

          induced_rule =
            @available_rules
            |> Enum.reject(fn rule -> rule in current_global_rules(state_with_updated_player) end)

          induced_rule =
            case induced_rule do
              [] -> Enum.random(@available_rules)
              candidates -> Enum.random(candidates)
            end

          induced_expires_at_ms = now_ms() + @effect_duration_ms

          Process.send_after(
            self(),
            {:clear_induced_rule, induced_rule, induced_expires_at_ms},
            @effect_duration_ms
          )

          new_state =
            state_with_updated_player
            |> Map.put(:induced_rule, induced_rule)
            |> Map.put(:induced_rule_expires_at_ms, induced_expires_at_ms)

          broadcast_player_list(new_state.players)
          broadcast_rules_update()

          {:reply, {:ok, updated_player}, new_state}
        else
          {:reply, {:error, :insufficient_score, player}, state}
        end
    end
  end

  @impl true
  def handle_call({:pause_random_rule, pid}, _from, state) do
    case find_player_by_pid(state.players, pid) do
      nil ->
        {:reply, {:error, :player_not_found}, state}

      player ->
        if enough_score?(player, @pause_random_rule_cost) do
          case pauseable_active_rules_for_player(state, pid) do
            [] ->
              {:reply, {:error, :no_rules_to_pause, player}, state}

            rules_for_player ->
              updated_player = apply_score_cost(player, @pause_random_rule_cost)
              state_with_updated_player = put_player(state, updated_player)

              paused_rule = Enum.random(rules_for_player)
              paused_expires_at_ms = now_ms() + @effect_duration_ms

              Process.send_after(
                self(),
                {:resume_paused_rule, pid, paused_rule, paused_expires_at_ms},
                @effect_duration_ms
              )

              paused_rules_by_pid =
                Map.put(state_with_updated_player.paused_rules_by_pid, pid, %{
                  rule: paused_rule,
                  expires_at_ms: paused_expires_at_ms
                })

              new_state =
                Map.put(state_with_updated_player, :paused_rules_by_pid, paused_rules_by_pid)

              broadcast_player_list(new_state.players)

              {:reply, {:ok, updated_player}, new_state}
          end
        else
          {:reply, {:error, :insufficient_score, player}, state}
        end
    end
  end

  @impl true
  def handle_call({:add_player, name, pid}, _from, state) do
    Process.monitor(pid)

    new_player = %Player{
      pid: pid,
      name: name
    }

    updated_player_list = [new_player | state.players]
    new_state = Map.put(state, :players, updated_player_list)

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:update_player_list, updated_player_list}
    )

    {:reply, new_player, new_state}
  end

  @impl true
  def handle_cast(:set_random_rule, state) do
    new_state = maybe_activate_random_rule(state)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1_000)

    current_game_time = state.current_game_time

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:tick_update, current_game_time}
    )

    state_with_new_rule =
      if rem(current_game_time, 30) == 0 do
        Phoenix.PubSub.broadcast(
          School.PubSub,
          "game_room",
          :update_rules
        )

        maybe_activate_random_rule(state)
      else
        state
      end

    if current_game_time > @max_game_time_seconds do
      Phoenix.PubSub.broadcast(
        School.PubSub,
        "game_room",
        {:game_ended, :ended}
      )
    end

    new_state =
      Map.put(state_with_new_rule, :current_game_time, current_game_time + 1)

    {:noreply, new_state}
  end

  # handle killed PID
  # {:DOWN, #Reference<0.4092222473.1123811329.133049>, :process, #PID<0.664.0>, {:shutdown, :closed}}
  @impl true
  def handle_info({:DOWN, _, _, pid, _}, state) do
    player_list = state.players
    updated_player_list = Enum.reject(player_list, fn player -> player.pid == pid end)
    new_state =
      state
      |> Map.put(:players, updated_player_list)
      |> Map.update!(:paused_rules_by_pid, &Map.delete(&1, pid))

    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:update_player_list, updated_player_list}
    )

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:clear_induced_rule, rule, expires_at_ms}, state) do
    new_state =
      if state.induced_rule == rule and state.induced_rule_expires_at_ms == expires_at_ms do
        state
        |> Map.put(:induced_rule, nil)
        |> Map.put(:induced_rule_expires_at_ms, nil)
      else
        state
      end

    if new_state != state do
      broadcast_rules_update()
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:resume_paused_rule, pid, rule, expires_at_ms}, state) do
    new_state =
      case Map.get(state.paused_rules_by_pid, pid) do
        %{rule: ^rule, expires_at_ms: ^expires_at_ms} ->
          Map.update!(state, :paused_rules_by_pid, &Map.delete(&1, pid))

        _ -> state
      end

    {:noreply, new_state}
  end

  def max_game_time do
    @max_game_time_seconds
  end

  defp maybe_activate_random_rule(state) do
    if length(state.active_rules) < @max_active_rules do
      activate_new_rule(state)
    else
      state
    end
  end

  defp activate_new_rule(state) do
    active_rules = state.active_rules

    new_rule =
      @available_rules
      |> Enum.reject(fn rule -> rule in active_rules end)
      |> Enum.random()

    new_state =
      Map.put(state, :active_rules, [new_rule | active_rules])

    new_state
  end

  defp sort_by_score(player_list) do
    Enum.sort(player_list, fn p1, p2 -> p1.score > p2.score end)
  end

  defp current_global_rules(state) do
    case state.induced_rule do
      nil -> state.active_rules
      induced_rule -> Enum.uniq([induced_rule | state.active_rules])
    end
  end

  defp active_rules_for_player(state, pid) do
    paused_rule =
      state
      |> paused_effect_for_pid(pid)
      |> paused_rule()

    state
    |> current_global_rules()
    |> Enum.reject(fn rule -> rule == paused_rule end)
  end

  defp pauseable_active_rules_for_player(state, pid) do
    paused_rule =
      state
      |> paused_effect_for_pid(pid)
      |> paused_rule()

    state.active_rules
    |> Enum.reject(fn rule -> rule == paused_rule end)
  end

  defp find_player_by_pid(player_list, pid) do
    Enum.find(player_list, fn player -> player.pid == pid end)
  end

  defp put_player(state, updated_player) do
    updated_players =
      Enum.map(state.players, fn player ->
        if player.pid == updated_player.pid, do: updated_player, else: player
      end)

    Map.put(state, :players, updated_players)
  end

  defp apply_score_cost(player, cost) do
    Map.put(player, :score, max(player.score - cost, 0))
  end

  defp enough_score?(player, cost) do
    player.score >= cost
  end

  defp combo_scored_player(player, :correct) do
    now = now_ms()

    combo_streak =
      if within_combo_window?(player.last_correct_at_ms, now) do
        player.combo_streak + 1
      else
        1
      end

    combo_multiplier =
      combo_streak
      |> scaled_combo_multiplier()
      |> min(@max_combo_multiplier)

    updated_player =
      player
      |> Map.put(:combo_streak, combo_streak)
      |> Map.put(:combo_multiplier, combo_multiplier)
      |> Map.put(:last_correct_at_ms, now)

    {updated_player, @base_correct_points * combo_multiplier}
  end

  defp combo_scored_player(player, :incorrect) do
    updated_player =
      player
      |> Map.put(:combo_streak, 0)
      |> Map.put(:combo_multiplier, 1)
      |> Map.put(:last_correct_at_ms, nil)

    {updated_player, @base_incorrect_points}
  end

  defp within_combo_window?(nil, _now), do: false

  defp within_combo_window?(last_correct_at_ms, now) do
    now - last_correct_at_ms <= @combo_window_ms
  end

  defp scaled_combo_multiplier(combo_streak) when combo_streak <= 1, do: 1

  defp scaled_combo_multiplier(combo_streak) do
    1 + div(combo_streak - 1, 2)
  end

  defp now_ms do
    System.monotonic_time(:millisecond)
  end

  defp seconds_left(nil, _now_ms), do: 0

  defp seconds_left(expires_at_ms, now_ms) do
    max(div(expires_at_ms - now_ms + 999, 1000), 0)
  end

  defp paused_effect_for_pid(_state, nil), do: nil

  defp paused_effect_for_pid(state, pid) do
    Map.get(state.paused_rules_by_pid, pid)
  end

  defp paused_rule(nil), do: nil
  defp paused_rule(%{rule: rule}), do: rule

  defp paused_seconds_left(nil, _now_ms), do: 0

  defp paused_seconds_left(%{expires_at_ms: expires_at_ms}, now_ms) do
    seconds_left(expires_at_ms, now_ms)
  end

  defp broadcast_player_list(player_list) do
    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      {:update_player_list, sort_by_score(player_list)}
    )
  end

  defp broadcast_rules_update do
    Phoenix.PubSub.broadcast(
      School.PubSub,
      "game_room",
      :update_rules
    )
  end

  defp maybe_start_game(player_list) do
    all_ready? = Enum.all?(player_list, fn player -> player.ready? end)

    if all_ready? do
      Phoenix.PubSub.broadcast(
        School.PubSub,
        "game_room",
        {:game_start, :in_progress}
      )

      Process.send_after(self(), :tick, 1_000)

      :in_progress
    else
      :waiting
    end
  end
end
