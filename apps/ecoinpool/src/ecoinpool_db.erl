
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ecoinpool.
%%
%% ecoinpool is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ecoinpool is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ecoinpool.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(ecoinpool_db).
-behaviour(gen_server).

-include("ecoinpool_db_records.hrl").

-export([start_link/1, get_subpool_record/1, get_configuration/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    srv_conn,
    conf_db
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link({DBHost, DBPort, DBPrefix, DBOptions}) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [{DBHost, DBPort, DBPrefix, DBOptions}], []).

get_configuration() ->
    gen_server:call(?MODULE, get_configuration).

get_subpool_record(SubpoolId) ->
    gen_server:call(?MODULE, {get_subpool_record, SubpoolId}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([{DBHost, DBPort, DBPrefix, DBOptions}]) ->
    % Connect to database
    S = couchbeam:server_connection(DBHost, DBPort, DBPrefix, DBOptions),
    % Open database
    ConfDb = case couchbeam:open_or_create_db(S, "ecoinpool", []) of
        {ok, TheConfDb} -> TheConfDb;
        {error, Error} -> io:format("couchbeam:open_or_create_db returned an error: ~p~n", [Error]), throw({error, Error})
    end,
    % Start config monitor (asynchronously)
    gen_server:cast(?MODULE, start_cfg_monitor),
    % Return initial state
    {ok, #state{srv_conn=S, conf_db=ConfDb}}.

handle_call(get_configuration, _From, State=#state{conf_db=ConfDb}) ->
    case couchbeam:open_doc(ConfDb, "configuration") of
        {ok, {DocProps}} ->
            % Unpack and parse data
            DocType = proplists:get_value(<<"type">>, DocProps),
            ActiveSubpoolIds = proplists:get_value(<<"active_subpools">>, DocProps, []),
            ActiveSubpoolIdsCheck = lists:all(fun is_binary/1, ActiveSubpoolIds),
            
            if % Validate data
                DocType =:= <<"configuration">>,
                ActiveSubpoolIdsCheck ->
                    % Create record
                    Configuration = #configuration{active_subpools=ActiveSubpoolIds},
                    {reply, {ok, Configuration}, State};
                true ->
                    {reply, {error, invalid}, State}
            end;
            
        _ ->
            {reply, {error, missing}, State}
    end;

handle_call({get_subpool_record, SubpoolId}, _From, State=#state{conf_db=ConfDb}) ->
    % Retrieve document
    case couchbeam:open_doc(ConfDb, SubpoolId) of
        {ok, {DocProps}} ->
            % Unpack and parse data
            DocType = proplists:get_value(<<"type">>, DocProps),
            Name = proplists:get_value(<<"name">>, DocProps),
            Port = proplists:get_value(<<"port">>, DocProps),
            PoolType = case proplists:get_value(<<"pool_type">>, DocProps) of
                <<"btc">> -> btc;
                <<"nmc">> -> nmc;
                <<"sc">> -> sc;
                _ -> undefined
            end,
            CoinDaemonConfig = case proplists:get_value(<<"coin_daemon">>, DocProps) of
                {CDP} ->
                    lists:map(
                        fun ({BinName, Value}) -> {binary_to_atom(BinName, utf8), Value} end,
                        CDP
                    );
                _ ->
                    []
            end,
            
            if % Validate data
                DocType =:= <<"sub-pool">>,
                is_binary(Name),
                Name =/= <<>>,
                is_integer(Port),
                PoolType =/= undefined ->
                    
                    % Create record
                    Subpool = #subpool{
                        id=SubpoolId,
                        name=Name,
                        port=Port,
                        pool_type=PoolType,
                        coin_daemon_config=CoinDaemonConfig
                    },
                    {reply, {ok, Subpool}, State};
                
                true ->
                    {reply, {error, invalid}, State}
            end;
        _ ->
            {reply, {error, missing}, State}
    end;

handle_call(_Message, _From, State=#state{}) ->
    {reply, error, State}.

handle_cast(start_cfg_monitor, State=#state{conf_db=ConfDb}) ->
    ok = ecoinpool_db_sup:start_cfg_monitor(ConfDb),
    {noreply, State};

handle_cast(_Message, State=#state{}) ->
    {noreply, State}.

handle_info(_Message, State=#state{}) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State=#state{}, _Extra) ->
    {ok, State}.
