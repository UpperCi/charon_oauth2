defmodule CharonOauth2.GenEctoMod.Grant do
  def generate(authorization_schema, config) do
    quote generated: true do
      @moduledoc """
      A grant is an (in-progress) Oauth2 flow to obtain auth tokens.

      Not every flow needs server-side state to be stored, for example, the implicit grant
      immediately returns an access token in response to the authorization request, and does
      not have a second exchange-code-for-token request-response cycle.
      """
      use Ecto.Schema
      import Ecto.Changeset
      import Ecto.Query, except: [preload: 2, preload: 3]
      alias Ecto.Query
      alias CharonOauth2.Types.Hmac
      alias CharonOauth2.Internal
      alias Charon.Internal, as: CharonInternal

      @type t :: %__MODULE__{}

      @config unquote(config)
      @mod_config Internal.get_module_config(@config)
      @auth_schema unquote(authorization_schema)

      @types ~w(authorization_code)
      @autogen_code {CharonInternal, :random_url_encoded, [32]}

      schema @mod_config.grant_table do
        field(:code, Hmac, autogenerate: @autogen_code, redact: true, config: @config)
        field(:redirect_uri, :string)
        field(:type, :string)
        field(:expires_at, :utc_datetime)

        belongs_to(:authorization, @auth_schema)

        timestamps(type: :utc_datetime)
      end

      @doc """
      Insert-only changeset - some things (should) never change.
      """
      @spec insert_only_changeset(__MODULE__.t() | Changeset.t(), map()) ::
              Changeset.t()
      def insert_only_changeset(struct_or_cs \\ %__MODULE__{}, params) do
        struct_or_cs
        |> cast(params, [:redirect_uri, :type, :authorization_id])
        |> validate_required([:redirect_uri, :type, :authorization_id])
        |> validate_inclusion(:type, @types, message: "must be one of: #{Enum.join(@types, ", ")}")
        |> prepare_changes(fn cs = %{data: data} ->
          redirect_uri = get_field(cs, :redirect_uri)
          type = get_field(cs, :type)
          auth_id = get_field(cs, :authorization_id)

          with authorization = %{client: client} <-
                 @auth_schema.preload(:client) |> cs.repo.get(auth_id),
               {_, true} <- {:uri, redirect_uri in client.redirect_uris},
               {_, true} <- {:type, type in client.grant_types} do
            %{cs | data: %{data | authorization: authorization}}
          else
            {:uri, false} -> add_error(cs, :redirect_uri, "does not match client")
            {:type, false} -> add_error(cs, :type, "not supported by client")
            nil -> cs
          end
        end)
        |> unique_constraint(:code)
        |> assoc_constraint(:authorization)
        |> put_change(
          :expires_at,
          DateTime.from_unix!(@mod_config.grant_ttl + CharonInternal.now())
        )
      end

      ###########
      # Queries #
      ###########

      @doc """
      Sets the current module name as a camelcase named binding in an Ecto query
      """
      @spec named_binding() :: Query.t()
      def named_binding() do
        from(u in __MODULE__, as: :charon_oauth2_grant)
      end

      @doc """
      Resolve named bindings that are not present in the query by (left-)joining to the appropriate tables.
      """
      @spec resolve_binding(Query.t(), atom()) :: Query.t()
      def resolve_binding(query, named_binding) do
        if has_named_binding?(query, named_binding) do
          query
        else
          case named_binding do
            :authorization ->
              join(query, :left, [charon_oauth2_grant: c], a in assoc(c, :authorization),
                as: :authorization
              )

            :authorization_client ->
              query
              |> resolve_binding(:authorization)
              |> join(:left, [authorization: a], c in assoc(a, :client), as: :client)

            :authorization_resource_owner ->
              query
              |> resolve_binding(:authorization)
              |> join(:left, [authorization: a], ro in assoc(a, :resource_owner),
                as: :resource_owner
              )

            _ ->
              query
          end
        end
      end

      @doc """
      Preload named bindings. Automatically joins using `resolve_binding/2`.
      """
      @spec preload(Query.t(), atom | [atom]) :: Query.t()
      def preload(query \\ named_binding(), named_binding_or_bindings)

      def preload(query, named_binding) when is_atom(named_binding) do
        case named_binding do
          :authorization ->
            query
            |> resolve_binding(:authorization)
            |> Query.preload([authorization: a], authorization: a)

          :authorization_client ->
            query
            |> resolve_binding(:authorization_client)
            |> Query.preload([authorization: a, client: c], authorization: {a, client: c})

          :authorization_resource_owner ->
            query
            |> resolve_binding(:authorization_resource_owner)
            |> Query.preload([authorization: a, resource_owner: ro],
              authorization: {a, resource_owner: ro}
            )
        end
      end

      def preload(query, list), do: Enum.reduce(list, query, &preload(&2, &1))

      @doc false
      def supported_preloads(),
        do: ~w(authorization authorization_client authorization_resource_owner)a
    end
  end
end
