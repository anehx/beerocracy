defmodule Beerocracy.Weather.Forecast do
  @moduledoc """
  What one evening is expected to look like.

  Beer is a weather-dependent activity — half the catalogue is terraces and
  courtyards, and the rest involves a walk — so the outlook belongs next to the
  day you are voting for, not on another website.

  Summarises the drinking window rather than the whole day. A day can peak at
  28°C at three in the afternoon and be a chilly 19°C by the time anybody sits
  down outside, so the daily high answers the wrong question. It is a range and
  not a single hour because an evening that starts sunny and ends under a
  downpour is exactly the evening worth knowing about in advance.
  """

  @enforce_keys [:date, :from_hour, :to_hour, :code, :temp_min, :temp_max, :rain]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          date: Date.t(),
          from_hour: 0..23,
          to_hour: 0..23,
          code: non_neg_integer(),
          temp_min: number(),
          temp_max: number(),
          rain: [{0..23, non_neg_integer(), number()}]
        }

  # WMO weather interpretation codes, as returned by Open-Meteo.
  @symbols %{
    0 => "☀️",
    1 => "🌤️",
    2 => "⛅",
    3 => "☁️",
    45 => "🌫️",
    48 => "🌫️",
    51 => "🌦️",
    53 => "🌦️",
    55 => "🌦️",
    56 => "🌧️",
    57 => "🌧️",
    61 => "🌧️",
    63 => "🌧️",
    65 => "🌧️",
    66 => "🌧️",
    67 => "🌧️",
    71 => "🌨️",
    73 => "🌨️",
    75 => "🌨️",
    77 => "🌨️",
    80 => "🌦️",
    81 => "🌧️",
    82 => "🌧️",
    85 => "🌨️",
    86 => "🌨️",
    95 => "⛈️",
    96 => "⛈️",
    99 => "⛈️"
  }

  @summaries %{
    0 => "Clear",
    1 => "Mostly clear",
    2 => "Partly cloudy",
    3 => "Overcast",
    45 => "Fog",
    48 => "Freezing fog",
    51 => "Light drizzle",
    53 => "Drizzle",
    55 => "Heavy drizzle",
    56 => "Freezing drizzle",
    57 => "Freezing drizzle",
    61 => "Light rain",
    63 => "Rain",
    65 => "Heavy rain",
    66 => "Freezing rain",
    67 => "Freezing rain",
    71 => "Light snow",
    73 => "Snow",
    75 => "Heavy snow",
    77 => "Snow grains",
    80 => "Light showers",
    81 => "Showers",
    82 => "Heavy showers",
    85 => "Snow showers",
    86 => "Snow showers",
    95 => "Thunderstorm",
    96 => "Thunderstorm with hail",
    99 => "Thunderstorm with hail"
  }

  # Drizzle, rain, snow and showers: the codes that promise something falling.
  @falling Enum.concat([51..67, 71..77, 80..86])
  @overcast 3

  @doc "A single glyph for the outlook, or a neutral one for an unknown code."
  @spec symbol(t() | non_neg_integer()) :: String.t()
  def symbol(%__MODULE__{} = forecast), do: forecast |> sky() |> symbol()
  def symbol(code), do: Map.get(@symbols, code, "🌡️")

  @doc "The outlook in words, for the tooltip and for screen readers."
  @spec summary(t() | non_neg_integer()) :: String.t()
  def summary(%__MODULE__{} = forecast), do: forecast |> sky() |> summary()
  def summary(code), do: Map.get(@summaries, code, "Unknown")

  # The code is the single worst hour, while the verdict weighs how much falls
  # and how likely it is. When the verdict calls the evening dry, a rain cloud
  # above the word "Dry" only contradicts it — so the verdict wins, and the code
  # drops to overcast: an hour the model thought wet was cloudy at the very
  # least. Thunder is left alone, since it is worth knowing about without rain.
  defp sky(%__MODULE__{code: code} = forecast) when code in @falling do
    case verdict(forecast) do
      %{level: 0} -> @overcast
      _wet_enough -> code
    end
  end

  defp sky(%__MODULE__{code: code}), do: code

  @doc """
  The temperature range across the window, as it appears on the tile.

  Collapses to one number when the range rounds to a single degree — "21°" says
  more than "21 - 21°".

  ## Examples

      iex> alias Beerocracy.Weather.Forecast
      iex> Forecast.temperature(%Forecast{date: ~D[2026-08-19], from_hour: 16, to_hour: 22,
      ...>   code: 0, temp_min: 18.6, temp_max: 23.2, rain: []})
      "19 - 23°"
  """
  @spec temperature(t()) :: String.t()
  def temperature(%__MODULE__{temp_min: low, temp_max: high}) do
    range(round(low), round(high), "°")
  end

  @doc """
  The verdict on the evening: what the rain will actually do, in words.

  Probability alone is misleading and this catalogue proves it — an evening can
  read 98% while the model expects 0.0 mm, which is a high chance of nothing in
  particular. So the wording is driven by how much falls and hedged by how
  likely it is, rather than shouting a percentage that answers neither question.

  Returns a phrase and a level from 0 (dry) to 4 (do not sit outside).

  ## Examples

      iex> alias Beerocracy.Weather.Forecast
      iex> Forecast.verdict(%Forecast{date: ~D[2026-08-19], from_hour: 16, to_hour: 22,
      ...>   code: 95, temp_min: 17.0, temp_max: 23.0, rain: [{16, 98, 0.0}]})
      %{phrase: "Few drops", level: 1}
  """
  @spec verdict(t()) :: %{phrase: String.t(), level: 0..4} | nil
  def verdict(%__MODULE__{rain: []}), do: nil

  def verdict(%__MODULE__{} = forecast) do
    say(severity(millimetres(forecast)), confidence(rain_peak(forecast)))
  end

  # No measurable rain: a few drops at worst, however confident the model is.
  defp say(:none, confidence) when confidence in [:unlikely, :possible],
    do: %{phrase: "Dry", level: 0}

  defp say(:none, _confident), do: %{phrase: "Few drops", level: 1}

  defp say(:light, :unlikely), do: %{phrase: "Dry", level: 0}
  defp say(:light, :possible), do: %{phrase: "Maybe drizzle", level: 1}
  defp say(:light, _likely), do: %{phrase: "Drizzle", level: 2}

  defp say(:moderate, confidence) when confidence in [:unlikely, :possible],
    do: %{phrase: "Maybe rain", level: 2}

  defp say(:moderate, _likely), do: %{phrase: "Rain", level: 3}

  defp say(:heavy, confidence) when confidence in [:unlikely, :possible],
    do: %{phrase: "Maybe heavy", level: 3}

  defp say(:heavy, _likely), do: %{phrase: "Heavy rain", level: 4}

  @doc """
  Representative millimetre values with the band each one stands for.

  Exposed so the rules page can build its table by asking `verdict/1` rather
  than restating the thresholds in prose, where they would quietly go stale.
  """
  @spec rain_bands() :: [{float(), String.t()}]
  def rain_bands do
    [
      {0.0, "nothing measurable"},
      {0.5, "under 1mm an hour"},
      {2.0, "1 to 4mm an hour"},
      {8.0, "over 4mm an hour"}
    ]
  end

  @doc "Representative chances with the band each one stands for."
  @spec chance_bands() :: [{non_neg_integer(), String.t()}]
  def chance_bands do
    [
      {10, "under 25%"},
      {40, "25 to 54%"},
      {65, "55 to 79%"},
      {98, "80% or more"}
    ]
  end

  @doc "The verdict for a given chance and millimetre reading, for the table."
  @spec verdict_for(non_neg_integer(), float()) :: %{phrase: String.t(), level: 0..4}
  def verdict_for(chance, millimetres), do: say(severity(millimetres), confidence(chance))

  defp severity(mm) when mm < 0.2, do: :none
  defp severity(mm) when mm < 1.0, do: :light
  defp severity(mm) when mm < 4.0, do: :moderate
  defp severity(_mm), do: :heavy

  defp confidence(nil), do: :unlikely
  defp confidence(chance) when chance < 25, do: :unlikely
  defp confidence(chance) when chance < 55, do: :possible
  defp confidence(chance) when chance < 80, do: :likely
  defp confidence(_chance), do: :certain

  @doc "The heaviest hour across the window, in millimetres."
  @spec millimetres(t()) :: float()
  def millimetres(%__MODULE__{rain: []}), do: 0.0

  def millimetres(%__MODULE__{rain: rain}),
    do: rain |> Enum.map(fn {_hour, _chance, mm} -> mm end) |> Enum.max()

  @doc """
  The highest chance across the window, or `nil` when it is not known.

  ## Examples

      iex> alias Beerocracy.Weather.Forecast
      iex> Forecast.rain_peak(%Forecast{date: ~D[2026-08-19], from_hour: 16, to_hour: 22,
      ...>   code: 61, temp_min: 18.0, temp_max: 20.0, rain: [{16, 12, 0.0}, {19, 95, 3.0}]})
      95
  """
  @spec rain_peak(t()) :: non_neg_integer() | nil
  def rain_peak(%__MODULE__{rain: []}), do: nil

  def rain_peak(%__MODULE__{rain: rain}),
    do: rain |> Enum.map(fn {_hour, chance, _mm} -> chance end) |> Enum.max()

  @doc """
  The hour rain becomes more likely than not, when the evening starts dry.

  `nil` when it is wet from the outset, or never — in both cases there is no
  turning point worth naming.

  ## Examples

      iex> alias Beerocracy.Weather.Forecast
      iex> Forecast.rain_arrives(%Forecast{date: ~D[2026-08-19], from_hour: 16, to_hour: 22,
      ...>   code: 61, temp_min: 18.0, temp_max: 20.0,
      ...>   rain: [{16, 5, 0.0}, {19, 20, 0.0}, {20, 80, 2.0}]})
      20
  """
  @spec rain_arrives(t()) :: 0..23 | nil
  def rain_arrives(%__MODULE__{} = forecast) do
    case Enum.split_while(forecast.rain, fn {_hour, chance, _mm} -> chance < 50 end) do
      {[], _wet_from_the_start} -> nil
      {_dry, []} -> nil
      {_dry, [{hour, _chance, _mm} | _rest]} -> hour
    end
  end

  @doc "The window this covers, as `\"16:00 - 22:00\"`."
  @spec window(t() | {0..23, 0..23}) :: String.t()
  def window(%__MODULE__{from_hour: from, to_hour: to}), do: window({from, to})
  def window({from, to}), do: "#{clock(from)} - #{clock(to)}"

  @doc """
  Whether an outdoor place is a bad idea.

  Judged on the verdict rather than the raw chance: spitting is survivable on a
  terrace, actual rain is not, and a confident 98% of nothing should not empty
  the courtyard.
  """
  @spec wet?(t()) :: boolean()
  def wet?(%__MODULE__{} = forecast) do
    case verdict(forecast) do
      %{level: level} -> level >= 3
      nil -> false
    end
  end

  defp range(same, same, unit), do: "#{same}#{unit}"
  defp range(low, high, unit), do: "#{low} - #{high}#{unit}"

  defp clock(hour), do: "#{String.pad_leading(to_string(hour), 2, "0")}:00"

  @doc """
  The full outlook in one line, for the tile's tooltip.

  ## Examples

      iex> Beerocracy.Weather.Forecast.describe(%Beerocracy.Weather.Forecast{
      ...>   date: ~D[2026-08-19], from_hour: 16, to_hour: 22, code: 2,
      ...>   temp_min: 18.6, temp_max: 23.2, rain: [{16, 5, 0.0}, {19, 8, 0.0}]
      ...> })
      "Partly cloudy between 16:00 and 22:00, 19 - 23°C. Dry — up to 8% chance, 0.0mm an hour."
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = forecast) do
    base =
      "#{summary(forecast)} between #{clock(forecast.from_hour)} and " <>
        "#{clock(forecast.to_hour)}, #{String.replace(temperature(forecast), "°", "°C")}"

    case verdict(forecast) do
      nil ->
        base

      %{phrase: phrase} ->
        millimetres = :erlang.float_to_binary(millimetres(forecast) * 1.0, decimals: 1)

        "#{base}. #{phrase} — up to #{rain_peak(forecast)}% chance, " <>
          "#{millimetres}mm an hour#{arriving(forecast)}."
    end
  end

  defp arriving(forecast) do
    case rain_arrives(forecast) do
      nil -> ""
      hour -> ", from about #{clock(hour)}"
    end
  end
end
