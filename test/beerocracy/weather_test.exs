defmodule Beerocracy.WeatherTest do
  # Not async: the forecast cache is a single `:persistent_term` entry shared by
  # the whole node, so these would seed each other's weather.
  use ExUnit.Case, async: false

  alias Beerocracy.Weather
  alias Beerocracy.Weather.Forecast
  alias Beerocracy.Weather.OpenMeteo
  alias Beerocracy.Week

  doctest Beerocracy.Weather.Forecast

  setup do
    on_exit(&Weather.clear/0)
    Weather.clear()
    :ok
  end

  describe "the cache" do
    test "is empty rather than exploding before the first fetch lands" do
      assert Weather.forecasts() == %{}
      assert Weather.for_date(~D[2026-08-19]) == nil
      assert Weather.for_week(Week.from_date(~D[2026-08-19])) == %{}
    end

    test "hands back what was published, keyed by date" do
      Weather.put(%{~D[2026-08-19] => forecast(~D[2026-08-19], 0)})

      assert %Forecast{code: 0} = Weather.for_date(~D[2026-08-19])
      assert Weather.for_date(~D[2026-08-20]) == nil
    end

    test "for_week/1 covers the five weekdays and nothing else" do
      week = Week.from_date(~D[2026-08-19])

      published =
        week.monday
        |> Date.range(week.sunday)
        |> Map.new(&{&1, forecast(&1, 0)})

      Weather.put(published)

      dates = week |> Weather.for_week() |> Map.keys() |> Enum.sort()

      assert dates == Enum.map(Week.weekdays(), &Week.date_of(week, &1))
      refute week.sunday in dates
    end

    test "skips a weekday the source had no answer for" do
      week = Week.from_date(~D[2026-08-19])
      wednesday = Week.date_of(week, :wednesday)

      Weather.put(%{wednesday => forecast(wednesday, 3)})

      assert Map.keys(Weather.for_week(week)) == [wednesday]
    end
  end

  describe "refresh/1" do
    test "fills the cache from the configured source" do
      assert :ok = Weather.refresh()

      week = Week.current()
      forecasts = Weather.for_week(week)

      assert map_size(forecasts) == length(Week.weekdays())

      for {_date, forecast} <- forecasts do
        assert %Forecast{} = forecast
        assert is_integer(forecast.code)
      end
    end
  end

  describe "parsing an Open-Meteo payload" do
    test "folds the drinking window into one forecast per day" do
      assert {:ok, [forecast]} =
               OpenMeteo.parse(
                 hourly(
                   [
                     "2026-08-19T15:00",
                     "2026-08-19T16:00",
                     "2026-08-19T19:00",
                     "2026-08-19T22:00"
                   ],
                   [0, 0, 2, 61],
                   [29.0, 27.0, 24.0, 19.0],
                   [0, 5, 40, 95]
                 ),
                 {16, 22}
               )

      # 15:00 is outside the window and must not drag the range up.
      assert forecast.temp_min == 19.0
      assert forecast.temp_max == 27.0
      assert forecast.rain == [{16, 5, 0.0}, {19, 40, 0.0}, {22, 95, 0.0}]
      assert Forecast.rain_peak(forecast) == 95
      assert forecast.from_hour == 16
      assert forecast.to_hour == 22
    end

    test "keeps the most severe sky in the window, not the last one" do
      assert {:ok, [forecast]} =
               OpenMeteo.parse(
                 hourly(
                   ["2026-08-19T16:00", "2026-08-19T18:00", "2026-08-19T21:00"],
                   [0, 95, 1],
                   [24.0, 22.0, 20.0],
                   [0, 90, 10]
                 ),
                 {16, 22}
               )

      assert forecast.code == 95
    end

    test "summarises every day in the payload separately" do
      assert {:ok, [first, second]} =
               OpenMeteo.parse(
                 hourly(
                   ["2026-08-19T17:00", "2026-08-19T20:00", "2026-08-20T17:00"],
                   [0, 1, 61],
                   [24.0, 21.0, 15.0],
                   [0, 10, 80]
                 ),
                 {16, 22}
               )

      assert first.date == ~D[2026-08-19]
      assert second.date == ~D[2026-08-20]
      assert second.temp_min == 15.0
    end

    test "honours a different window" do
      payload =
        hourly(
          ["2026-08-19T12:00", "2026-08-19T13:00", "2026-08-19T20:00"],
          [0, 1, 61],
          [26.0, 28.0, 18.0],
          [0, 0, 70]
        )

      assert {:ok, [lunch]} = OpenMeteo.parse(payload, {12, 13})
      assert lunch.temp_min == 26.0
      assert lunch.temp_max == 28.0
    end

    test "leaves out a day with no usable hours in the window" do
      assert {:ok, []} =
               OpenMeteo.parse(hourly(["2026-08-19T09:00"], [0], [18.0], [0]), {16, 22})
    end

    test "tolerates missing rain probabilities across the window" do
      assert {:ok, [forecast]} =
               OpenMeteo.parse(
                 hourly(["2026-08-19T17:00", "2026-08-19T18:00"], [0, 0], [22.0, 21.0], [nil, nil]),
                 {16, 22}
               )

      assert forecast.rain == []
      assert Forecast.rain_peak(forecast) == nil
      assert Forecast.verdict(forecast) == nil
    end

    test "drops an hour whose measurements are null rather than rendering blanks" do
      assert {:ok, [forecast]} =
               OpenMeteo.parse(
                 hourly(["2026-08-19T17:00", "2026-08-19T18:00"], [nil, 0], [22.0, 21.0], [0, 0]),
                 {16, 22}
               )

      assert forecast.temp_max == 21.0
    end

    test "rejects a payload that is not a forecast at all" do
      assert {:error, :unexpected_payload} = OpenMeteo.parse(%{"error" => true}, {16, 22})
    end
  end

  describe "Forecast" do
    test "maps weather codes to a symbol and words" do
      assert Forecast.symbol(0) == "☀️"
      assert Forecast.summary(0) == "Clear"
      assert Forecast.symbol(95) == "⛈️"
      assert Forecast.summary(95) == "Thunderstorm"
    end

    test "does not draw rain over an evening the verdict calls dry" do
      # One drizzly hour sets the code, but next to nothing is expected to fall.
      forecast = window_forecast(code: 61, rain: [{16, 10, 0.0}, {19, 20, 0.1}])

      assert Forecast.verdict(forecast).phrase == "Dry"
      assert Forecast.symbol(forecast) == "☁️"
      assert Forecast.summary(forecast) == "Overcast"
      assert Forecast.describe(forecast) =~ ~r/^Overcast between/
    end

    test "keeps the rain symbol once the verdict expects something to fall" do
      forecast = window_forecast(code: 61, rain: [{16, 40, 0.5}])

      assert Forecast.verdict(forecast).phrase == "Maybe drizzle"
      assert Forecast.symbol(forecast) == "🌧️"
      assert Forecast.summary(forecast) == "Light rain"
    end

    test "keeps the thunderstorm even when little rain falls" do
      forecast = window_forecast(code: 95, rain: [{16, 10, 0.0}])

      assert Forecast.symbol(forecast) == "⛈️"
      assert Forecast.summary(forecast) == "Thunderstorm"
    end

    test "falls back for a code it has never seen" do
      assert Forecast.symbol(4242) == "🌡️"
      assert Forecast.summary(4242) == "Unknown"
    end

    test "prints the temperature as a rounded range" do
      assert Forecast.temperature(window_forecast(temp_min: 18.6, temp_max: 23.2)) == "19 - 23°"
    end

    test "collapses a range that rounds to one degree" do
      assert Forecast.temperature(window_forecast(temp_min: 20.8, temp_max: 21.2)) == "21°"
    end

    test "reports the peak chance and the heaviest hour" do
      forecast = window_forecast(rain: [{16, 12, 0.0}, {20, 95, 3.0}])

      assert Forecast.rain_peak(forecast) == 95
      assert Forecast.millimetres(forecast) == 3.0
      assert Forecast.rain_peak(window_forecast(rain: [])) == nil
    end

    test "a confident forecast of nothing in particular is not rain" do
      # Monday in the real catalogue: 98% chance, 0.0mm expected.
      forecast = window_forecast(rain: [{16, 90, 0.0}, {19, 98, 0.0}])

      assert Forecast.verdict(forecast) == %{phrase: "Few drops", level: 1}
      refute Forecast.wet?(forecast), "98% of nothing should not empty the terrace"
    end

    test "hedges an unlikely forecast and asserts a confident one" do
      assert Forecast.verdict(window_forecast(rain: [{16, 40, 2.0}])).phrase == "Maybe rain"
      assert Forecast.verdict(window_forecast(rain: [{16, 90, 2.0}])).phrase == "Rain"
    end

    test "scales the wording with how much actually falls" do
      phrase = fn mm -> Forecast.verdict(window_forecast(rain: [{16, 90, mm}])).phrase end

      assert phrase.(0.0) == "Few drops"
      assert phrase.(0.5) == "Drizzle"
      assert phrase.(2.0) == "Rain"
      assert phrase.(8.0) == "Heavy rain"
    end

    test "says nothing at all when there is no rain data" do
      assert Forecast.verdict(window_forecast(rain: [])) == nil
    end

    test "names the hour rain arrives, when the evening starts dry" do
      assert Forecast.rain_arrives(
               window_forecast(rain: [{16, 5, 0.0}, {19, 20, 0.0}, {20, 80, 3.0}])
             ) == 20
    end

    test "names no arrival when it is wet from the start or never" do
      assert Forecast.rain_arrives(window_forecast(rain: [{16, 90, 3.0}, {20, 95, 3.0}])) == nil
      assert Forecast.rain_arrives(window_forecast(rain: [{16, 5, 0.0}, {20, 10, 0.0}])) == nil
      assert Forecast.rain_arrives(window_forecast(rain: [])) == nil
    end

    test "calls it wet only once the rain is worth avoiding" do
      # Spitting is survivable on a terrace; actual rain is not.
      refute Forecast.wet?(window_forecast(rain: [{16, 0, 0.0}, {20, 95, 0.5}]))
      assert Forecast.wet?(window_forecast(rain: [{16, 0, 0.0}, {20, 95, 3.0}]))
      refute Forecast.wet?(window_forecast(rain: []))
    end

    test "renders the window as clock times" do
      assert Forecast.window({16, 22}) == "16:00 - 22:00"
      assert Forecast.window(window_forecast()) == "16:00 - 22:00"
      assert Forecast.window({9, 11}) == "09:00 - 11:00"
    end

    test "describes the window in one line" do
      assert Forecast.describe(
               window_forecast(
                 code: 2,
                 temp_min: 18.6,
                 temp_max: 23.2,
                 rain: [{16, 0, 0.0}, {20, 0, 0.0}]
               )
             ) ==
               "Partly cloudy between 16:00 and 22:00, 19 - 23°C. Dry — up to 0% chance, 0.0mm an hour."
    end

    test "says when the rain turns up, since that is what decides the evening" do
      assert Forecast.describe(
               window_forecast(
                 code: 61,
                 temp_min: 18.0,
                 temp_max: 20.0,
                 rain: [{16, 5, 0.0}, {20, 90, 3.0}]
               )
             ) =~ "up to 90% chance, 3.0mm an hour, from about 20:00"
    end

    test "leaves the rain out when it is unknown" do
      assert Forecast.describe(window_forecast(code: 0, temp_min: 20.0, temp_max: 20.0, rain: [])) ==
               "Clear between 16:00 and 22:00, 20°C"
    end
  end

  defp window_forecast(overrides \\ []) do
    defaults = [
      date: ~D[2026-08-19],
      from_hour: 16,
      to_hour: 22,
      code: 0,
      temp_min: 18.0,
      temp_max: 22.0,
      rain: [{16, 0, 0.0}, {19, 5, 0.0}, {22, 10, 0.0}]
    ]

    struct!(Forecast, Keyword.merge(defaults, overrides))
  end

  defp hourly(times, codes, temps, rain) do
    %{
      "hourly" => %{
        "time" => times,
        "weather_code" => codes,
        "temperature_2m" => temps,
        "precipitation_probability" => rain
      }
    }
  end

  defp forecast(date, code, temp_max \\ 21.0) do
    %Forecast{
      date: date,
      from_hour: 16,
      to_hour: 22,
      code: code,
      temp_min: temp_max - 4,
      temp_max: temp_max,
      rain: [{16, 0, 0.0}, {19, 5, 0.0}, {22, 10, 0.0}]
    }
  end
end
