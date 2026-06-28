defmodule School.Player do
  @type t :: %__MODULE__{
          name: String.t(),
          score: integer(),
          pid: pid(),
      ready?: boolean(),
      combo_streak: non_neg_integer(),
      combo_multiplier: pos_integer(),
      last_correct_at_ms: integer() | nil
        }

  defstruct name: nil,
            score: 0,
            pid: nil,
            ready?: false,
            combo_streak: 0,
            combo_multiplier: 1,
            last_correct_at_ms: nil
end
