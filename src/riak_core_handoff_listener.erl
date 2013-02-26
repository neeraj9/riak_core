%% -------------------------------------------------------------------
%%
%% riak_handoff_listener: entry point for TCP-based handoff
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc entry point for TCP-based handoff

-module(riak_core_handoff_listener).
-behavior(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
-export([get_handoff_ip/0, sock_opts/0, new_connection/2]).
-record(state, {
          ipaddr :: string(),
          portnum :: integer(),
          lsock ::gen_utp:utpsock(),
          ssl_opts :: list()
         }).

start_link() ->
    PortNum = app_helper:get_env(riak_core, handoff_port),
    IpAddr = app_helper:get_env(riak_core, handoff_ip),
    SslOpts = riak_core_handoff_sender:get_handoff_ssl_options(),
    gen_server:start_link({local,?MODULE}, ?MODULE, [IpAddr, PortNum, SslOpts], []).

get_handoff_ip() ->
    riak_core_gen_server:call(?MODULE, handoff_ip, infinity).

init([IpAddr, PortNum, SslOpts]) ->
    %% This exit() call shouldn't be necessary, AFAICT the VM's EXIT
    %% propagation via linking should do the right thing, but BZ 823
    %% suggests otherwise.  However, the exit() call should fall into
    %% the "shouldn't hurt", especially since the next line will
    %% explicitly try to spawn a new proc that will try to register
    %% the riak_kv_handoff_listener name.
    catch exit(whereis(riak_kv_handoff_listener), kill),
    process_proxy:start_link(riak_kv_handoff_listener, ?MODULE),

    self() ! start_listen,
    {ok, #state{portnum=PortNum, ipaddr=IpAddr, ssl_opts = SslOpts}}.

sock_opts() -> [binary, {packet, 4}].

handle_call(handoff_ip, _From, State=#state{ipaddr=I}) ->
    {reply, {ok, I}, State};

handle_call(handoff_port, _From, State=#state{portnum=P}) ->
    {reply, {ok, P}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(start_listen, #state{portnum=Port, ipaddr=IpAddr}=State) ->
    SockOpts = [{ip, IpAddr},{active,false}|sock_opts()],
    case gen_utp:listen(Port, SockOpts) of
        {ok, LSock} ->
            {ok, _Ref} = gen_utp:async_accept(LSock),
            {noreply, State#state{lsock=LSock}};
        Err ->
            {stop, Err, State}
    end;
handle_info({utp_async, S, _}, #state{lsock=LSock}=State) ->
    case new_connection(S, State) of
        {ok, NewState} ->
            {ok, _Ref} = gen_utp:async_accept(LSock),
            {noreply, NewState};
        Else ->
            Else
    end;
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, #state{lsock=LSock}) when LSock /= undefined ->
    gen_utp:close(LSock),
    ok;
terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

new_connection(Socket, State = #state{ssl_opts = SslOpts}) ->
    case riak_core_handoff_manager:add_inbound(SslOpts) of
        {ok, Pid} ->
            gen_utp:controlling_process(Socket, Pid),
            ok = riak_core_handoff_receiver:set_socket(Pid, Socket),
            {ok, State};
        {error, _Reason} ->
            riak_core_stat:update(rejected_handoffs),
            gen_utp:close(Socket),
            {ok, State}
    end.
