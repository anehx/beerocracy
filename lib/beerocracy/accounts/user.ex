defmodule Beerocracy.Accounts.User do
  @moduledoc """
  One citizen of the Beerocracy, as vouched for by GitHub.

  Two names live on this row and they do different jobs. `github_id` is the
  identity: a number GitHub hands out once and never reissues, which is what
  every vote is filed under. `display_name` is what the sheet calls you, it is
  yours to change, and nothing is keyed on it — so renaming yourself on a
  Wednesday afternoon does not orphan Monday's votes.

  `github_login` sits between the two. It is neither stable enough to key votes
  on (people rename their GitHub accounts) nor decorative — it is the name an
  admin is called by in the environment — so it is refreshed on every sign-in.
  """

  use Ash.Resource,
    otp_app: :beerocracy,
    domain: Beerocracy.Accounts,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshAuthentication]

  sqlite do
    table "users"
    repo Beerocracy.Repo
  end

  authentication do
    # Sessions carry the token's id, so signing out can revoke it rather than
    # merely asking the browser to forget.
    session_identifier :jti

    tokens do
      enabled? true
      token_resource Beerocracy.Accounts.Token
      signing_secret Beerocracy.Secrets
      store_all_tokens? true
    end

    strategies do
      github do
        client_id Beerocracy.Secrets
        client_secret Beerocracy.Secrets
        redirect_uri Beerocracy.Secrets
        identity_resource Beerocracy.Accounts.UserIdentity
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :github_id, :string,
      allow_nil?: false,
      public?: true,
      description: "GitHub's numeric account id, as a string. Never changes, never reused."

    attribute :github_login, :string,
      allow_nil?: false,
      public?: true,
      description: "The @handle. Refreshed on every sign-in, because people rename themselves."

    attribute :display_name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 40],
      description: "What the sheet calls this person. Theirs to change."

    attribute :email, :ci_string,
      allow_nil?: true,
      public?: false,
      description: "Only ever read from GitHub. The sheet has no use for it and never shows it."

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_github_id, [:github_id]
  end

  actions do
    defaults [:read, :destroy]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT."
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :by_github_id do
      description "Look up the account behind a GitHub id."
      get? true
      argument :github_id, :string, allow_nil?: false
      filter expr(github_id == ^arg(:github_id))
    end

    create :register_with_github do
      description """
      Arrival from GitHub, whether for the first time or the fiftieth.

      `upsert_fields` is the important line: coming back through GitHub
      refreshes the handle and the email, and pointedly leaves `display_name`
      alone. That name was chosen here, and a sign-in must not quietly undo a
      rename.
      """

      # `user_info` is Assent's *normalised* profile, not GitHub's raw /user
      # body: the id arrives as "sub" and the handle as "preferred_username".
      # See `Assent.Strategy.Github.normalize/2`.
      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false

      upsert? true
      upsert_identity :unique_github_id
      upsert_fields [:github_login, :email, :updated_at]

      change AshAuthentication.GenerateTokenChange
      change AshAuthentication.Strategy.OAuth2.IdentityChange

      change fn changeset, _context ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info)

        Ash.Changeset.change_attributes(changeset, %{
          # Left nil rather than coerced when absent, so a profile without them
          # fails the attribute's own check instead of quietly creating an
          # account keyed on an empty string.
          github_id: user_info["sub"] && to_string(user_info["sub"]),
          github_login: user_info["preferred_username"],
          email: user_info["email"],
          display_name: Beerocracy.Accounts.available_name(user_info)
        })
      end
    end

    update :rename do
      description "Change what the sheet calls this person."
      accept [:display_name]
    end
  end

  @doc """
  The key every one of this person's votes is filed under.

  Derived from the GitHub id rather than stored, so there is exactly one place
  the answer can come from. The `gh:` prefix keeps these apart from the
  name-derived keys written before there was any such thing as signing in.
  """
  @spec voter_key(t()) :: String.t()
  # Matched on `__struct__` rather than `%__MODULE__{}`: Ash only defines the
  # struct at `@before_compile`, so the struct syntax cannot expand in here.
  def voter_key(%{__struct__: __MODULE__, github_id: github_id}), do: "gh:" <> github_id

  @type t :: %__MODULE__{}
end
