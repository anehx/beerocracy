defmodule BeerocracyWeb.BallotLive do
  @moduledoc """
  The whole application: one ballot sheet for the current ISO week.

  Everyone lands on the same sheet, works down it — register, day, place —
  and watches the tally at the bottom fill in as their friends vote.
  """

  use BeerocracyWeb, :live_view

  alias Beerocracy.Accounts
  alias Beerocracy.Accounts.Scope
  alias Beerocracy.Ballot
  alias Beerocracy.Minutes
  alias Beerocracy.Places
  alias Beerocracy.Places.Opening
  alias Beerocracy.Places.Place
  alias Beerocracy.Weather
  alias Beerocracy.Weather.Forecast
  alias Beerocracy.Week

  import BeerocracyWeb.PlaceComponents

  # How many cards of the deck are rendered as a visible stack.
  @stack_depth 3

  @impl true
  def mount(_params, _session, socket) do
    week = Week.current()

    if connected?(socket) do
      Ballot.subscribe(week)
      # Catches the Sunday-to-Monday rollover without anyone having to reload.
      :timer.send_interval(:timer.minutes(1), self(), :tick)
    end

    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: "Week #{week.week}",
       week: week,
       today: Week.today(),
       voter_name: Scope.voter_name(scope),
       voter_key: Scope.voter_key(scope),
       day_stances: %{},
       decided: %{},
       undone: nil,
       renaming?: false
     )
     |> restore_voter_state()
     |> assign_tally()}
  end

  @impl true
  def handle_event("rename", _params, socket) do
    {:noreply, assign(socket, renaming?: true)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, renaming?: false)}
  end

  def handle_event("save_name", %{"display_name" => name}, %{assigns: assigns} = socket) do
    case require_voter(socket) do
      {:ok, socket} ->
        {:noreply, save_name(socket, assigns.current_scope.user, name)}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("cycle_day", %{"weekday" => weekday}, %{assigns: assigns} = socket) do
    with {:ok, socket} <- require_voter(socket),
         {:ok, weekday} <- parse_weekday(weekday),
         {:ok, socket} <- require_ahead(socket, weekday) do
      days = Ballot.cycle_day(assigns.week, assigns.voter_name, assigns.voter_key, weekday)
      {:noreply, socket |> assign(day_stances: days) |> assign_tally()}
    else
      {:error, socket} -> {:noreply, socket}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("swipe", %{"slug" => slug, "liked" => liked}, %{assigns: assigns} = socket) do
    with {:ok, socket} <- require_voter(socket),
         {:ok, place} <- Places.fetch(slug) do
      Ballot.swipe(assigns.week, assigns.voter_name, assigns.voter_key, place.slug, !!liked)

      {:noreply,
       socket
       |> assign(decided: Map.put(assigns.decided, place.slug, !!liked), undone: nil)
       |> assign_tally()}
    else
      {:error, socket} -> {:noreply, socket}
      :error -> {:noreply, put_flash(socket, :error, "That place is no longer in the catalogue.")}
    end
  end

  def handle_event("reset_vote", _params, %{assigns: assigns} = socket) do
    case require_voter(socket) do
      {:ok, socket} ->
        cleared = Ballot.reset_voter(assigns.week, assigns.voter_key)

        {:noreply,
         socket
         |> assign(day_stances: %{}, decided: %{}, undone: nil)
         |> assign_tally()
         |> put_flash(:info, reset_message(cleared))}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "record_visit",
        %{"week_key" => week_key, "weekday" => weekday, "slug" => slug},
        %{assigns: assigns} = socket
      ) do
    with {:ok, socket} <- require_admin(socket),
         {:ok, week} <- Ballot.week_from_key(week_key, assigns.week),
         {:ok, weekday} <- parse_weekday(weekday),
         {:ok, place} <- Places.fetch(slug) do
      Minutes.record(week, weekday, place.slug, assigns.voter_name)

      {:noreply,
       socket
       |> assign_tally()
       |> put_flash(:info, "Week #{week.week}: #{Week.label(weekday)} at #{place.name}.")}
    else
      {:error, socket} -> {:noreply, socket}
      :error -> {:noreply, put_flash(socket, :error, "That is not a week and a place.")}
    end
  end

  def handle_event("clear_visit", %{"week_key" => week_key}, %{assigns: assigns} = socket) do
    with {:ok, socket} <- require_admin(socket),
         {:ok, week} <- Ballot.week_from_key(week_key, assigns.week) do
      Minutes.forget(week)

      {:noreply,
       socket
       |> assign_tally()
       |> put_flash(:info, "Week #{week.week} is back to whatever the vote says.")}
    else
      {:error, socket} -> {:noreply, socket}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("undo", _params, %{assigns: assigns} = socket) do
    with {:ok, socket} <- require_voter(socket),
         {:ok, slug} <- Ballot.undo_last_swipe(assigns.week, assigns.voter_key) do
      {:noreply,
       socket
       |> assign(decided: Map.delete(assigns.decided, slug), undone: slug)
       |> assign_tally()}
    else
      {:error, socket} -> {:noreply, socket}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:ballot_updated, _week_key}, socket) do
    {:noreply, assign_tally(socket)}
  end

  def handle_info(:tick, %{assigns: assigns} = socket) do
    week = Week.current()
    socket = assign(socket, today: Week.today())

    if week.key == assigns.week.key do
      # Same week; the countdown in the header moved, and — once a day — the
      # tile for yesterday closed itself.
      {:noreply, assign(socket, week: week)}
    else
      # A new week: the old sheet is spent, everybody starts clean.
      Ballot.subscribe(week)

      {:noreply,
       socket
       |> assign(
         week: week,
         page_title: "Week #{week.week}",
         day_stances: %{},
         decided: %{}
       )
       |> restore_voter_state()
       |> assign_tally()}
    end
  end

  defp save_name(%{assigns: assigns} = socket, user, name) do
    case Accounts.rename(user, name) do
      {:ok, renamed} ->
        # The name is copied onto every vote as it is cast, so the copies have
        # to follow it, or the tally goes on using the old one.
        Ballot.rename_voter(
          assigns.week,
          Scope.voter_key(assigns.current_scope),
          renamed.display_name
        )

        socket
        |> assign(
          current_scope: Scope.for_user(renamed),
          voter_name: renamed.display_name,
          renaming?: false
        )
        |> assign_tally()
        |> put_flash(:info, "The sheet will call you #{renamed.display_name} from now on.")

      {:error, reason} ->
        put_flash(socket, :error, name_error(reason))
    end
  end

  defp name_error(:blank), do: "A name with nothing in it is no name at all."
  defp name_error(:too_long), do: "That is longer than #{Accounts.name_limit()} characters."
  defp name_error(:taken), do: "Somebody on the sheet already goes by that. Pick another."
  defp name_error(_other), do: "That name would not save."

  defp restore_voter_state(%{assigns: %{voter_key: nil}} = socket), do: socket

  defp restore_voter_state(%{assigns: assigns} = socket) do
    state = Ballot.voter_state(assigns.week, assigns.voter_key)
    assign(socket, day_stances: state.days, decided: state.places)
  end

  defp require_voter(%{assigns: %{voter_key: nil}} = socket) do
    {:error, put_flash(socket, :error, "Sign in first, then vote.")}
  end

  defp require_voter(socket), do: {:ok, socket}

  # The template only draws the controls for an admin; this is what actually
  # stops anybody else, since an event can be sent without the button.
  defp require_admin(%{assigns: %{current_scope: %{admin?: true}}} = socket), do: {:ok, socket}

  defp require_admin(socket) do
    {:error, put_flash(socket, :error, "That is not yours to set.")}
  end

  # The tile for a day that has been disables itself, but a sheet left open over
  # midnight is a minute behind the calendar, so the event is checked too — and
  # against the clock now, not the one the page was rendered with.
  defp require_ahead(%{assigns: assigns} = socket, weekday) do
    if Week.past?(Week.date_of(assigns.week, weekday)) do
      {:error,
       socket
       |> assign(today: Week.today())
       |> put_flash(:error, "#{Week.label(weekday)} has been and gone.")}
    else
      {:ok, socket}
    end
  end

  # Never `String.to_atom/1` on user input; only the five days on the ballot map
  # to an atom at all.
  defp parse_weekday(value) do
    case Enum.find(Week.weekdays(), &(Atom.to_string(&1) == value)) do
      nil -> :error
      weekday -> {:ok, weekday}
    end
  end

  defp assign_tally(%{assigns: assigns} = socket) do
    tally = Ballot.tally(assigns.week)
    outcome = Ballot.outcome(tally)
    forecasts = Weather.for_week(assigns.week)
    history = Ballot.history(assigns.week, 4)

    pending =
      assigns.week
      |> Ballot.pending_places(assigns.decided, {assigns.week.key, assigns.voter_key})
      |> pin_undone(assigns.undone)

    assign(socket,
      tally: tally,
      weather: forecasts,
      window: Weather.window(),
      pending: pending,
      deck: Enum.take(pending, @stack_depth),
      total_places: length(Places.available(assigns.week)),
      leading_day: Ballot.winning_day(tally),
      outcome: outcome,
      soaking: Ballot.soaking_risk(outcome, forecasts),
      history: history,
      recorded: Ballot.recorded_visit(assigns.week),
      visits: Ballot.last_visits(assigns.week)
    )
  end

  # A card you just took back goes straight to the top of the deck. You undid the
  # swipe because you want to judge it again now, not in six cards' time.
  defp pin_undone(places, nil), do: places

  defp pin_undone(places, slug) do
    case Enum.split_with(places, &(&1.slug == slug)) do
      {[place], rest} -> [place | rest]
      _ -> places
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="ballot" class="px-0 py-0 sm:px-6 sm:py-10">
        <div class="sheet animate-sheet">
          <div class="sheet-perforation"></div>
          <div class="h-2 bg-bottle"></div>

          <.masthead week={@week} voters={@tally.voters} />

          <.register_section
            voter_name={@voter_name}
            week={@week.week}
            renaming?={@renaming?}
            limit={Accounts.name_limit()}
          />

          <.day_section
            locked={is_nil(@voter_key)}
            today={@today}
            days={@tally.days}
            stances={@day_stances}
            leading={@leading_day}
            weather={@weather}
            window={@window}
          />

          <.place_section
            locked={is_nil(@voter_key)}
            deck={@deck}
            pending={@pending}
            decided={@decided}
            total={@total_places}
            undone={@undone}
            week={@week}
            visits={@visits}
            waiting?={@decided != %{} and not Ballot.counts?(@tally, @day_stances)}
            busy_on={busy_on(@tally, @day_stances)}
          />

          <.tally_section
            tally={@tally}
            outcome={@outcome}
            soaking={@soaking}
            history={@history}
            recorded={@recorded}
            week={@week}
            admin?={@current_scope.admin?}
          />

          <.colophon />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Masthead ───────────────────────────────────────────────────────────────

  attr :week, Week, required: true
  attr :voters, :list, required: true

  defp masthead(assigns) do
    ~H"""
    <header class="flex flex-wrap items-start justify-between gap-4 px-5 pt-6 pb-5 sm:px-10 sm:pt-8">
      <div>
        <h1 class="wordmark">Beerocracy</h1>
        <p class="eyebrow mt-2 text-ink-soft">One beer · one week · one vote each</p>
        <p :if={@voters != []} class="data mt-3 text-ink-soft">
          On the sheet: {Enum.join(@voters, ", ")}
        </p>
      </div>

      <div class="flex flex-col items-end gap-2">
        <div class="stamp stamp-week animate-stamp">
          <span class="text-[0.5rem] tracking-[0.3em]">Calendar week</span>
          <span class="text-3xl leading-none tracking-tight">{@week.week}</span>
          <span class="text-[0.5rem]">{date_range(@week)}</span>
        </div>
        <p class="data text-ink-soft">Resets in {reset_countdown(@week)}</p>
      </div>
    </header>
    """
  end

  # ── Article I — the register ───────────────────────────────────────────────

  attr :voter_name, :string, default: nil
  attr :week, :integer, required: true
  attr :renaming?, :boolean, default: false
  attr :limit, :integer, required: true

  defp register_section(assigns) do
    ~H"""
    <section class="sheet-section">
      <.article_header no="I" title="The register">
        GitHub says who you are, so nobody can vote as you and the sheet remembers what
        you already picked. What it calls you on the sheet is up to you, and changing it
        costs you nothing — no vote is filed under your name.
      </.article_header>

      <div :if={is_nil(@voter_name)} class="mt-5 flex flex-wrap items-center gap-4">
        <.link href={~p"/auth/user/github"} class="btn">
          <.icon name="hero-arrow-right-end-on-rectangle" class="mr-2 size-4" /> Sign in with GitHub
        </.link>
        <p class="text-ink-soft">Read the sheet all you like; marking it needs a name.</p>
      </div>

      <form
        :if={@voter_name && @renaming?}
        phx-submit="save_name"
        class="mt-5 flex flex-wrap items-end gap-3"
      >
        <label class="min-w-48 flex-1">
          <span class="eyebrow text-ink-soft">What the sheet calls you</span>
          <input
            type="text"
            name="display_name"
            value={@voter_name}
            class="field mt-1"
            autocomplete="nickname"
            maxlength={@limit}
            required
          />
        </label>
        <button type="submit" class="btn">Save</button>
        <button type="button" phx-click="cancel_rename" class="btn btn-quiet">Cancel</button>
      </form>

      <div :if={@voter_name && !@renaming?} class="mt-5 flex flex-wrap items-center gap-3">
        <p class="mr-auto text-xl font-extrabold uppercase [font-stretch:82%]">
          Signed: {@voter_name}
        </p>
        <button type="button" phx-click="rename" class="btn btn-quiet">Change name</button>
        <button
          type="button"
          phx-click="reset_vote"
          data-confirm={"Clear your days and swipes for week #{@week}? Everyone else's marks stay."}
          class="btn btn-quiet"
        >
          Reset my vote
        </button>
        <.link href={~p"/sign-out"} method="delete" class="btn btn-quiet">Sign out</.link>
      </div>
    </section>
    """
  end

  # ── Article II — the day ───────────────────────────────────────────────────

  attr :locked, :boolean, required: true
  attr :today, Date, required: true
  attr :days, :list, required: true
  attr :stances, :map, required: true
  attr :leading, :any, default: nil
  attr :weather, :map, required: true
  attr :window, :any, required: true

  defp day_section(assigns) do
    ~H"""
    <section class="sheet-section" data-locked={@locked || nil}>
      <.article_header no="II" title="Which day">
        Tap a day for yes, tap again for maybe, once more to clear it. Mark as many as
        you like — a maybe counts towards the day just like a yes, so say maybe if you
        could be talked into it. Days that have already been are closed: the sheet
        runs from today to Saturday.
      </.article_header>

      <div :if={@weather != %{}} class="mt-5 flex items-baseline gap-2">
        <span class="eyebrow text-ink-soft">Outlook {Forecast.window(@window)}</span>
        <span class="h-px flex-1 bg-rule"></span>
      </div>

      <div class="mt-3 grid grid-cols-6 gap-1 sm:gap-2.5">
        <button
          :for={day <- @days}
          type="button"
          phx-click="cycle_day"
          phx-value-weekday={day.weekday}
          disabled={@locked or Week.past?(day.date, @today)}
          data-stance={@stances[day.weekday]}
          data-past={Week.past?(day.date, @today) || nil}
          data-leader={(@leading && @leading.weekday == day.weekday) || nil}
          class="day-tile"
          aria-label={day_label(day, @stances[day.weekday], @today)}
        >
          <.outlook forecast={@weather[day.date]} />
          <span class="day-tile-label">{Week.short_label(day.weekday)}</span>
          <span class="day-tile-date">{Calendar.strftime(day.date, "%-d.%-m.")}</span>
          <span class="day-tile-stance">{stance_label(@stances[day.weekday])}</span>
          <span class="day-tile-count">{tally_marks(day.count)}</span>
        </button>
      </div>

      <%!-- The sentence each tile used to keep in a tooltip. A phone cannot
            hover, so it is printed here in full, behind one toggle for the row.
            Client-side only: JS commands survive the patches every vote causes. --%>
      <div :if={@weather != %{}} class="mt-4">
        <button
          type="button"
          id="outlook-toggle"
          class="data text-ink-soft underline underline-offset-2 hover:text-ink"
          aria-controls="outlook-detail"
          aria-expanded="false"
          phx-click={
            JS.toggle(to: "#outlook-detail")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          }
        >
          The outlook in full
        </button>
        <dl id="outlook-detail" class="mt-2 hidden space-y-1.5">
          <div :for={day <- @days} :if={@weather[day.date]} class="data flex gap-3 text-ink-soft">
            <dt class="w-8 shrink-0 font-bold">
              <span aria-hidden="true">{Week.short_label(day.weekday)}</span>
              <span class="sr-only">{Week.label(day.weekday)}</span>
            </dt>
            <dd class="min-w-0 flex-1">{Forecast.describe(@weather[day.date])}</dd>
          </div>
        </dl>
      </div>

      <p class="data mt-4 text-ink-soft">
        Your answer is the word on the tile. The strokes underneath are everyone's,
        maybes included.
      </p>
    </section>
    """
  end

  attr :forecast, Forecast, default: nil

  defp outlook(assigns) do
    ~H"""
    <%!-- Rendered even when the forecast is missing, so a day the API has no
          answer for does not make its tile shorter than the other four. --%>
    <span class="day-tile-weather">
      <span :if={@forecast} class="day-tile-sky" aria-hidden="true">
        {Forecast.symbol(@forecast)}
      </span>
      <span :if={@forecast} class="day-tile-temp">
        {Forecast.temperature(@forecast)}<span class="sr-only">
          C, {Forecast.describe(@forecast)}</span>
      </span>
      <%!-- The verdict, not a percentage: an evening can read 98% and expect
            0.0mm, which is a high chance of nothing in particular. --%>
      <span
        :if={@forecast && Forecast.verdict(@forecast)}
        class="day-tile-rain"
        data-level={Forecast.verdict(@forecast).level}
      >
        {Forecast.verdict(@forecast).phrase}
      </span>
      <span :if={is_nil(@forecast)} class="day-tile-sky" aria-hidden="true">·</span>
    </span>
    """
  end

  # ── Article III — the place ────────────────────────────────────────────────

  attr :locked, :boolean, required: true
  attr :deck, :list, required: true
  attr :pending, :list, required: true
  attr :decided, :map, required: true
  attr :total, :integer, required: true
  attr :undone, :string, default: nil
  attr :week, Week, required: true
  attr :visits, :map, required: true
  attr :waiting?, :boolean, default: false
  attr :busy_on, :any, default: nil

  defp place_section(assigns) do
    assigns = assign(assigns, decided_count: map_size(assigns.decided))

    ~H"""
    <section class="sheet-section" data-locked={@locked || nil}>
      <.article_header no="III" title="Which place">
        Swipe right to approve, left to reject. The keyboard arrows work too, and so do
        the buttons — nobody is watching.
      </.article_header>

      <%!-- Their swipes are recorded but parked. Say so where they are swiping,
            not only in the tally where they might never look. --%>
      <div :if={@waiting?} class="mt-4 border-2 border-oxide bg-oxide/10 p-3">
        <p class="note text-ink">
          <span class="font-bold">Your swipes are not counting yet.</span>
          <%!-- Two ways to end up here: no day marked at all, or marked days
                that the winning one is not among. Say which. --%>
          <span :if={is_nil(@busy_on)}>
            Pick a day in Article II first — if you are not coming, you do not get to
            choose where.
          </span>
          <span :if={@busy_on}>
            {Week.label(@busy_on)} is winning and you have not marked it, so you would not
            be there — mark it, even as a maybe, and your swipes join in.
          </span>
          Nothing is lost; they start counting the moment you do.
        </p>
        <%!-- The other honest answer to "no day picked" is that they genuinely
              cannot make it, in which case leaving swipes parked forever helps
              nobody. Offer the way out rather than only the way forward. --%>
        <p class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-2">
          <span class="data text-ink-soft">Cannot make it this week?</span>
          <button
            type="button"
            phx-click="reset_vote"
            data-confirm={"Clear your swipes for week #{@week.week}? Everyone else's marks stay."}
            class="btn btn-quiet !px-3 text-xs"
          >
            Clear my swipes
          </button>
        </p>
      </div>

      <div class="mt-3 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <span class="data text-ink-soft">
          {@decided_count} of {@total} judged
        </span>
        <span :if={@undone} class="data text-oxide">Back on the deck</span>
        <.link navigate={~p"/places"} class="data font-bold underline underline-offset-2">
          Just browsing? See all {@total} →
        </.link>
      </div>

      <div :if={@pending != []} class="mt-4">
        <div
          id="deck"
          class="deck"
          phx-hook=".SwipeDeck"
          tabindex="0"
          role="group"
          aria-label="Places to judge"
        >
          <.swipe_card
            :for={{place, depth} <- Enum.with_index(@deck)}
            place={place}
            depth={depth}
            position={@decided_count + depth + 1}
            total={@total}
            week={@week}
            last_visit={@visits[place.slug]}
          />
        </div>

        <div class="mt-5 flex items-center justify-center gap-3 sm:gap-5">
          <button
            type="button"
            class="btn btn-reject"
            disabled={@locked}
            phx-click={JS.dispatch("beerocracy:vote", to: "#deck", detail: %{liked: false})}
            aria-label="Reject this place"
          >
            Reject
          </button>

          <button
            type="button"
            class="btn btn-quiet !px-3 text-xs"
            disabled={@locked or @decided_count == 0}
            phx-click="undo"
          >
            Undo
          </button>

          <button
            type="button"
            class="btn btn-approve"
            disabled={@locked}
            phx-click={JS.dispatch("beerocracy:vote", to: "#deck", detail: %{liked: true})}
            aria-label="Approve this place"
          >
            Approve
          </button>
        </div>
      </div>

      <div :if={@pending == [] and @decided_count > 0} class="mt-6 flex flex-col items-start gap-4">
        <div class="stamp stamp-week animate-stamp text-lg">Ballot complete</div>
        <p class="note">
          Every place in the catalogue has your verdict. You approved {approved_names(@decided)}.
        </p>
        <button type="button" class="btn btn-quiet" phx-click="undo">Take back the last one</button>
      </div>

      <p :if={@pending == [] and @decided_count == 0} class="note mt-6">
        The catalogue is empty. Add a place to <code class="data">priv/places.yml</code>
        and it appears here.
      </p>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SwipeDeck">
        // Tinder-style deck. The gesture, the tilt and the rubber stamps all live
        // here; the server only ever hears the final verdict.
        const THROW = 110          // px of travel that counts as a decision
        const FLY_MS = 320         // must match .swipe-card[data-flying] in app.css

        export default {
          mounted() {
            this.pointerId = null
            this.settling = false

            this.onDown = (e) => this.start(e)
            this.onMove = (e) => this.move(e)
            this.onUp = (e) => this.end(e)
            this.onKey = (e) => {
              if (e.key === "ArrowRight") { e.preventDefault(); this.decide(true) }
              if (e.key === "ArrowLeft") { e.preventDefault(); this.decide(false) }
            }
            this.onVote = (e) => this.decide(!!e.detail.liked)

            this.el.addEventListener("pointerdown", this.onDown)
            this.el.addEventListener("pointermove", this.onMove)
            this.el.addEventListener("pointerup", this.onUp)
            this.el.addEventListener("pointercancel", this.onUp)
            this.el.addEventListener("keydown", this.onKey)
            this.el.addEventListener("beerocracy:vote", this.onVote)
          },

          destroyed() {
            this.el.removeEventListener("pointerdown", this.onDown)
            this.el.removeEventListener("pointermove", this.onMove)
            this.el.removeEventListener("pointerup", this.onUp)
            this.el.removeEventListener("pointercancel", this.onUp)
            this.el.removeEventListener("keydown", this.onKey)
            this.el.removeEventListener("beerocracy:vote", this.onVote)
          },

          top() {
            return this.el.querySelector('.swipe-card[data-depth="0"]:not([data-flying])')
          },

          start(e) {
            const card = this.top()
            if (!card || !card.contains(e.target) || this.pointerId !== null) return
            this.pointerId = e.pointerId
            this.originX = e.clientX
            this.originY = e.clientY
            this.dx = 0
            this.card = card
            card.setAttribute("data-dragging", "")
            card.removeAttribute("data-settling")
            card.setPointerCapture(e.pointerId)
          },

          move(e) {
            if (e.pointerId !== this.pointerId || !this.card) return
            this.dx = e.clientX - this.originX
            const dy = e.clientY - this.originY
            // Beyond a wrist-flick the card should feel thrown, not dragged.
            this.paint(this.dx, dy, this.dx / (this.el.clientWidth || 320))
          },

          end(e) {
            if (e.pointerId !== this.pointerId || !this.card) return
            const card = this.card
            card.releasePointerCapture?.(e.pointerId)
            card.removeAttribute("data-dragging")
            this.pointerId = null

            if (Math.abs(this.dx) >= THROW) {
              this.throw(card, this.dx > 0)
            } else {
              card.setAttribute("data-settling", "")
              this.paint(0, 0, 0)
              setTimeout(() => card.removeAttribute("data-settling"), 300)
            }
            this.card = null
          },

          decide(liked) {
            const card = this.top()
            if (card) this.throw(card, liked)
          },

          // Off it goes. The event is pushed once the card has left the sheet, so
          // the re-render never interrupts the throw.
          throw(card, liked) {
            if (card.hasAttribute("data-flying")) return
            const slug = card.dataset.slug
            const width = this.el.clientWidth || 320
            card.removeAttribute("data-settling")
            card.setAttribute("data-flying", "")
            this.paintCard(card, liked ? width * 1.6 : -width * 1.6, -40, liked ? 1 : -1)
            setTimeout(() => this.pushEvent("swipe", {slug, liked}), FLY_MS - 60)
          },

          paint(dx, dy, progress) {
            if (this.card) this.paintCard(this.card, dx, dy * 0.35, progress)
          },

          paintCard(card, dx, dy, progress) {
            card.style.transform = `translate3d(${dx}px, ${dy}px, 0) rotate(${dx * 0.045}deg)`
            const approve = card.querySelector(".stamp-approve")
            const reject = card.querySelector(".stamp-reject")
            if (approve) approve.style.opacity = Math.min(Math.max(progress, 0) * 2.2, 0.9)
            if (reject) reject.style.opacity = Math.min(Math.max(-progress, 0) * 2.2, 0.9)
          }
        }
      </script>
    </section>
    """
  end

  attr :place, Place, required: true
  attr :depth, :integer, required: true
  attr :position, :integer, required: true
  attr :total, :integer, required: true
  attr :week, Week, required: true
  attr :last_visit, :integer, default: nil

  defp swipe_card(assigns) do
    ~H"""
    <article
      id={"card-#{@place.slug}"}
      class="swipe-card"
      data-depth={@depth}
      data-slug={@place.slug}
      style={"--band: var(--color-accent-#{@place.accent})"}
      aria-hidden={@depth > 0}
    >
      <div class="card-band"></div>

      <div class="p-4 sm:p-6">
        <div class="flex items-start justify-between gap-3">
          <span class="text-4xl leading-none" aria-hidden="true">{@place.emoji}</span>
          <span class="data text-ink-soft">
            {pad(@position)} / {pad(@total)}
          </span>
        </div>

        <h3 class="mt-3 text-2xl font-extrabold uppercase [font-stretch:80%] leading-none sm:text-3xl">
          {@place.name}
        </h3>
        <p class="note mt-2">{@place.tagline}</p>
        <.opening place={@place} week={@week} />

        <dl class="mt-4 space-y-3 border-t border-rule pt-4">
          <.rating label="Beer" rating={@place.beer_rating} note={@place.beer_note} />
          <.rating label="Food" rating={@place.food_rating} note={@place.food_note} />
        </dl>

        <div class="mt-4 grid grid-cols-2 gap-3 border-t border-rule pt-4">
          <.journey label="Office" reach={@place.office} />
          <.journey label="Station" reach={@place.station} />
        </div>

        <div class="mt-4 flex flex-wrap items-center gap-1.5">
          <.last_visit weeks_ago={@last_visit} />
          <span :if={@place.outdoor?} class="chip">outdoors</span>
          <span :for={tag <- @place.tags} class="chip">{tag}</span>
        </div>
      </div>

      <div class="stamp stamp-verdict stamp-approve" aria-hidden="true">Approved</div>
      <div class="stamp stamp-verdict stamp-reject" aria-hidden="true">Rejected</div>
    </article>
    """
  end

  # ── Article IV — the tally ─────────────────────────────────────────────────

  attr :tally, :any, required: true
  attr :outcome, :any, default: nil
  attr :soaking, :any, default: nil
  attr :history, :list, default: []
  attr :recorded, :any, default: nil
  attr :week, Week, required: true
  attr :admin?, :boolean, default: false

  defp tally_section(assigns) do
    ~H"""
    <section class="sheet-section">
      <.article_header no="IV" title="The tally">
        Live, and wiped clean every Monday at 00:00. {@tally.day_votes_cast} day {pluralize_votes(
          @tally.day_votes_cast
        )} and {@tally.place_votes_cast} swipes recorded.
      </.article_header>

      <div :if={@recorded} class="mt-6 border-2 border-ink bg-ink p-5 text-paper">
        <p class="eyebrow flex items-baseline justify-between gap-3 opacity-80">
          <span>In the end</span>
          <button
            :if={@admin?}
            type="button"
            phx-click="clear_visit"
            phx-value-week_key={@week.key}
            class="underline underline-offset-2 opacity-80 hover:opacity-100"
          >
            Back to the vote
          </button>
        </p>
        <p class="mt-2 text-2xl font-extrabold uppercase [font-stretch:80%] leading-tight sm:text-3xl">
          {Week.label(@recorded.weekday)} at {@recorded.place.name}
        </p>
        <p class="data mt-2 opacity-80">
          {Calendar.strftime(@recorded.date, "%d.%m.%Y")} · written down by {@recorded.recorded_by}
        </p>
      </div>

      <div
        :if={Ballot.decided?(@outcome)}
        class="mt-6 border-2 border-bottle bg-bottle p-5 text-paper"
      >
        <p class="eyebrow opacity-80">
          {if @recorded, do: "What the vote said", else: "As it stands"}
        </p>
        <p class="mt-2 text-2xl font-extrabold uppercase [font-stretch:80%] leading-tight sm:text-3xl">
          {Week.label(@outcome.day.weekday)} at {place_names(@outcome.places)}
        </p>
        <p class="data mt-2 opacity-80">
          {Calendar.strftime(@outcome.day.date, "%d.%m.%Y")} · {@outcome.day.count} for the day{maybe_suffix(
            @outcome.day
          )} · {hd(@outcome.places).likes} for the place{tied_suffix(@outcome.places)}
        </p>

        <%!-- The most-liked place cannot host the winning day, so say so rather
              than quietly promoting the runner-up. --%>
        <p :if={@outcome.blocked} class="mt-3 border-t border-paper/30 pt-3 text-sm leading-snug">
          <span class="font-bold">{@outcome.blocked.place.name}</span>
          has more approvals but is shut on {Week.label(@outcome.day.weekday)}<span :if={
            Opening.describe(@outcome.blocked.place.opening)
          }>
            — {Opening.describe(@outcome.blocked.place.opening)}</span>.
        </p>

        <p :if={@soaking} class="mt-3 border-t border-paper/30 pt-3 text-sm leading-snug">
          <span aria-hidden="true">{Forecast.symbol(@soaking)}</span>
          Outdoors, and {Week.label(@outcome.day.weekday)} looks wet —
          <span class="font-bold">
            {@soaking |> Forecast.verdict() |> Map.fetch!(:phrase) |> String.downcase()}
          </span>
          between {Forecast.window(@soaking)}, up to {Forecast.rain_peak(@soaking)}% chance.
        </p>
      </div>

      <p :if={not Ballot.decided?(@outcome)} class="note mt-6">
        <span :if={is_nil(@outcome)}>No day has a tick yet.</span>
        <span :if={@outcome}>
          {Week.label(@outcome.day.weekday)} is leading, but nothing approved is open then.<span :if={
            @outcome.blocked
          }>
            <span class="font-bold text-ink">{@outcome.blocked.place.name}</span>
            is shut on {Week.label(@outcome.day.weekday)}<span :if={
              Opening.describe(@outcome.blocked.place.opening)
            }> — {Opening.describe(@outcome.blocked.place.opening)}</span>.</span>
        </span>
        The floor is open.
      </p>

      <p :if={@tally.waiting != []} class="note mt-4 text-oxide">
        <span class="font-bold">Not counting yet:</span>
        {Enum.join(@tally.waiting, ", ")} {pluralise_have(@tally.waiting)} swiped but {pluralise_are(
          @tally.waiting
        )} not down for {leading_label(@outcome)}, so those swipes are
        parked — shown as <span class="font-bold">+n?</span>
        below — until that changes.
      </p>

      <h3 class="eyebrow mt-8 text-ink-soft">Days</h3>
      <p class="data mt-1 text-ink-soft">Solid is a yes, hatched is a maybe. Both count.</p>
      <div class="mt-3 space-y-2">
        <div :for={day <- @tally.days} id={"tally-day-#{day.weekday}"}>
          <div class="flex items-center gap-3">
            <span class="data w-8 shrink-0 font-bold">{Week.short_label(day.weekday)}</span>
            <div class="tally-bar flex-1">
              <div
                class="tally-fill"
                style={"width: #{share(day.yes_count, max_day_count(@tally))}%"}
              >
              </div>
              <div
                class="tally-fill"
                data-tentative
                style={"width: #{share(day.maybe_count, max_day_count(@tally))}%"}
              >
              </div>
            </div>
            <span class="data w-28 shrink-0 truncate text-right text-ink-soft">
              {day_summary(day)}
            </span>
          </div>
          <p :if={day.count > 0} class="names data mt-1 pl-11 text-ink-soft">
            <span :if={day.certain != []}>Yes: {Enum.join(day.certain, ", ")}</span>
            <span :if={day.tentative != []}>Maybe: {Enum.join(day.tentative, ", ")}</span>
          </p>
        </div>
      </div>

      <div :if={@history != []}>
        <h3 class="eyebrow mt-8 text-ink-soft">Where we went</h3>
        <p class="data mt-1 text-ink-soft">
          So nobody proposes the same pub four weeks running.<span :if={
            Enum.any?(@history, &Ballot.Visit.recorded?/1)
          }>
            "Recorded" is where an admin says we actually went, not what the vote said.
          </span>
        </p>
        <ol class="mt-3 space-y-1.5">
          <li :for={visit <- @history} class="flex items-baseline gap-3">
            <span class="data w-16 shrink-0 font-bold">W{visit.week.week}</span>
            <span class="data w-8 shrink-0 text-ink-soft">{Week.short_label(visit.weekday)}</span>
            <span class="min-w-0 flex-1 truncate">
              <span aria-hidden="true">{visit.place.emoji}</span> {visit.place.name}
              <span :if={Ballot.Visit.recorded?(visit)} class="data text-ink-soft">
                · recorded by {visit.recorded_by}
              </span>
            </span>
            <button
              :if={@admin? and Ballot.Visit.recorded?(visit)}
              type="button"
              phx-click="clear_visit"
              phx-value-week_key={visit.week.key}
              class="data shrink-0 text-ink-soft underline underline-offset-2 hover:text-ink"
            >
              clear
            </button>
            <span class="data shrink-0 text-ink-soft">+{visit.likes}</span>
          </li>
        </ol>
      </div>

      <h3 class="eyebrow mt-8 text-ink-soft">Places</h3>
      <div class="mt-1">
        <div
          :for={{position, result} <- Ballot.ranked(@tally.places)}
          id={"tally-place-#{result.place.slug}"}
          class="rank-row"
        >
          <%!-- Blank for a drawn place: a league table prints the position once
                and leaves the rows below it empty. --%>
          <span class="rank-no">{position && pad(position)}</span>
          <div class="min-w-0">
            <p class="truncate font-bold uppercase [font-stretch:86%]">
              <span aria-hidden="true">{result.place.emoji}</span> {result.place.name}
            </p>
            <div class="tally-bar mt-1.5 max-w-64">
              <div
                class="tally-fill"
                style={"width: #{share(result.likes, max_place_likes(@tally))}%"}
              >
              </div>
            </div>
            <p :if={judged?(result)} class="names data mt-1.5 text-ink-soft">
              <span :if={result.fans != []}>For: {Enum.join(result.fans, ", ")}</span>
              <span :if={result.critics != []}>Against: {Enum.join(result.critics, ", ")}</span>
              <span :if={result.waiting != []} class="text-oxide">
                Waiting: {Enum.join(result.waiting, ", ")}
              </span>
            </p>
          </div>
          <span class="data whitespace-nowrap text-ink-soft">
            <span class="font-bold text-ink">+{result.likes}</span>
            / −{result.dislikes}<span
              :if={result.waiting_likes + result.waiting_dislikes > 0}
              class="text-oxide"
            >
              · +{result.waiting_likes}?</span>
          </span>
        </div>
      </div>

      <div :if={@admin?} class="mt-8 border-2 border-dashed border-rule p-5">
        <h3 class="eyebrow text-ink-soft">The minutes</h3>
        <p class="note mt-2">
          The ballot says where we agreed to go, which is not always where we went.
          Writing it down here corrects that week — in the archive, and in the
          "we were there recently" note on the cards. It changes no votes.
        </p>

        <form phx-submit="record_visit" class="mt-4 flex flex-wrap items-end gap-3">
          <label>
            <span class="eyebrow text-ink-soft">Week</span>
            <select name="week_key" class="field mt-1">
              <option :for={{key, label} <- recordable_weeks(@week, @history)} value={key}>
                {label}
              </option>
            </select>
          </label>

          <label>
            <span class="eyebrow text-ink-soft">Day</span>
            <select name="weekday" class="field mt-1">
              <option
                :for={weekday <- Week.weekdays()}
                value={weekday}
                selected={weekday == default_weekday(@recorded, @outcome)}
              >
                {Week.label(weekday)}
              </option>
            </select>
          </label>

          <label class="min-w-48 flex-1">
            <span class="eyebrow text-ink-soft">Where we went</span>
            <%!-- The whole catalogue, not just what was open: a place being shut
                  on paper is exactly the sort of thing this exists to correct. --%>
            <select name="slug" class="field mt-1">
              <option
                :for={place <- Places.all()}
                value={place.slug}
                selected={place.slug == default_slug(@recorded, @outcome)}
              >
                {place.name}
              </option>
            </select>
          </label>

          <button type="submit" class="btn">Write it down</button>
        </form>
      </div>
    </section>
    """
  end

  # This week first, then the weeks already on the sheet — the archive is read
  # back from votes, so those are the only past weeks there is anything to say
  # about.
  defp recordable_weeks(week, history) do
    [{week.key, "W#{week.week} · this week"}] ++
      Enum.map(history, &{&1.week.key, "W#{&1.week.week}"})
  end

  defp default_weekday(%Ballot.Visit{weekday: weekday}, _outcome), do: weekday
  defp default_weekday(nil, %{day: %{weekday: weekday}}), do: weekday
  defp default_weekday(nil, _undecided), do: :thursday

  defp default_slug(%Ballot.Visit{place: place}, _outcome), do: place.slug
  defp default_slug(nil, %{places: [%{place: place} | _]}), do: place.slug
  defp default_slug(nil, _undecided), do: nil

  # ── Shared bits ────────────────────────────────────────────────────────────

  attr :no, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp article_header(assigns) do
    ~H"""
    <div>
      <p class="article-no">Article {@no}</p>
      <h2 class="section-heading mt-1">{@title}</h2>
      <p class="note mt-2">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  defp colophon(assigns) do
    ~H"""
    <footer class="border-t-2 border-ink bg-paper-edge/40 px-5 py-6 sm:px-10">
      <p class="note text-[0.8125rem]">
        The list of places lives in <.catalogue_link>priv/places.yml</.catalogue_link>. Adding your local is a pull
        request, not a deployment — copy an entry, fill it in, open the PR. It shows up
        on the next deploy.
      </p>
      <p class="mt-3 flex flex-wrap gap-x-5 gap-y-2">
        <a
          :if={Places.edit_url()}
          href={Places.edit_url()}
          target="_blank"
          rel="noopener noreferrer"
          class="data font-bold underline underline-offset-2"
        >
          Add a place on GitHub ↗
        </a>
        <.link navigate={~p"/places"} class="data font-bold underline underline-offset-2">
          Read the whole list without voting →
        </.link>
        <.link navigate={~p"/rules"} class="data font-bold underline underline-offset-2">
          How this all works →
        </.link>
      </p>
    </footer>
    """
  end

  defp date_range(%Week{monday: monday, sunday: sunday}) do
    "#{Calendar.strftime(monday, "%-d")} - #{Calendar.strftime(sunday, "%-d %b")}"
  end

  defp reset_countdown(week) do
    seconds = Week.seconds_until_reset(week)
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{div(rem(seconds, 3600), 60)}m"
      true -> "#{div(seconds, 60)}m"
    end
  end

  # Counts on a paper ballot are kept in fives, gate by gate.
  defp tally_marks(0), do: "·"

  defp tally_marks(count) do
    String.duplicate("卌 ", div(count, 5)) <> String.duplicate("|", rem(count, 5))
  end

  defp reset_message(%{days: 0, places: 0}), do: "Nothing to clear — you had not voted yet."

  defp reset_message(%{days: days, places: places}) do
    "Cleared #{days} #{pluralize(days, "day")} and #{places} #{pluralize(places, "swipe")}. Start again whenever."
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  # The word printed on the tile, which is also what a screen reader announces.
  defp stance_label(:yes), do: "Yes"
  defp stance_label(:maybe), do: "Maybe"
  defp stance_label(nil), do: "—"

  defp day_label(day, stance, today) do
    cond do
      not Week.past?(day.date, today) ->
        "#{Week.label(day.weekday)}: #{stance_label(stance)}"

      is_nil(stance) ->
        "#{Week.label(day.weekday)}: been and gone, closed to voting"

      true ->
        "#{Week.label(day.weekday)}: been and gone, your answer was #{stance_label(stance)}"
    end
  end

  defp place_names(places), do: places |> Enum.map(& &1.place.name) |> to_sentence()

  # The winning weekday, when the voter has marked days but not that one.
  defp busy_on(_tally, day_stances) when map_size(day_stances) == 0, do: nil

  defp busy_on(tally, day_stances) do
    case Ballot.winning_day(tally) do
      nil -> nil
      day -> if Map.has_key?(day_stances, day.weekday), do: nil, else: day.weekday
    end
  end

  defp tied_suffix([_only]), do: ""
  defp tied_suffix(places), do: ", #{length(places)} ways"

  defp to_sentence([one]), do: one
  defp to_sentence([a, b]), do: "#{a} or #{b}"

  defp to_sentence(names) do
    {rest, [last]} = Enum.split(names, -1)
    "#{Enum.join(rest, ", ")} or #{last}"
  end

  defp maybe_suffix(%{maybe_count: 0}), do: ""
  defp maybe_suffix(%{maybe_count: maybe}), do: " (#{maybe} maybe)"

  defp day_summary(%{count: 0}), do: "—"
  defp day_summary(%{count: count, maybe_count: 0}), do: "#{count}"
  defp day_summary(%{count: count, maybe_count: maybe}), do: "#{count} · #{maybe} maybe"

  # Whether anybody at all has swiped on this place, parked swipes included.
  defp judged?(%{fans: [], critics: [], waiting: []}), do: false
  defp judged?(_result), do: true

  defp approved_names(decided) do
    case decided |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)) |> Places.filter() do
      [] -> "nothing at all, which is a position"
      places -> places |> Enum.map(& &1.name) |> Enum.join(", ")
    end
  end

  defp max_day_count(tally), do: tally.days |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)

  defp max_place_likes(tally),
    do: tally.places |> Enum.map(& &1.likes) |> Enum.max(fn -> 0 end)

  defp share(_value, 0), do: 0
  defp share(value, max), do: round(value / max * 100)

  defp pad(number), do: number |> to_string() |> String.pad_leading(2, "0")

  defp pluralise_have([_only]), do: "has"
  defp pluralise_have(_many), do: "have"

  defp pluralise_are([_only]), do: "is"
  defp pluralise_are(_many), do: "are"

  defp leading_label(nil), do: "any day"
  defp leading_label(%{day: day}), do: Week.label(day.weekday)

  defp pluralize_votes(1), do: "vote"
  defp pluralize_votes(_), do: "votes"
end
