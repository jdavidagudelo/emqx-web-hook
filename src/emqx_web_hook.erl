%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(emqx_web_hook).

-include_lib("emqx/include/emqx.hrl").

-define(APP, emqx_web_hook).

-export([load/0, unload/0]).

-export([on_client_connected/4, on_client_disconnected/3]).
-export([on_client_subscribe/3, on_client_unsubscribe/3]).
-export([on_session_created/3, on_session_subscribed/4, on_session_unsubscribed/4,
         on_session_terminated/3]).
-export([on_message_publish/2, on_message_delivered/3, on_message_acked/3]).

-define(LOG(Level, Format, Args), emqx_logger:Level("WebHook: " ++ Format, Args)).

load() ->
    lists:foreach(
      fun({Hook, Fun, Filter}) ->
        load_(Hook, binary_to_atom(Fun, utf8), Filter, {Filter})
      end, parse_rule(application:get_env(?APP, rules, []))).

unload() ->
    lists:foreach(
      fun({Hook, Fun, Filter}) ->
          unload_(Hook, binary_to_atom(Fun, utf8), Filter)
      end, parse_rule(application:get_env(?APP, rules, []))).

%%--------------------------------------------------------------------
%% Client connected
%%--------------------------------------------------------------------

on_client_connected(#{client_id := ClientId, username := Username}, 0, _ConnInfo, _Env) ->
    Params = [{action, client_connected},
              {client_id, ClientId},
              {username, Username},
              {conn_ack, 0}],
    send_http_request(Params),
    ok;

on_client_connected(#{}, _ConnAck, _ConnInfo, _Env) ->
    ok.

%%--------------------------------------------------------------------
%% Client disconnected
%%--------------------------------------------------------------------

on_client_disconnected(#{}, auth_failure, _Env) ->
    ok;
on_client_disconnected(Client, {shutdown, Reason}, Env) when is_atom(Reason) ->
    on_client_disconnected(Reason, Client, Env);
on_client_disconnected(#{client_id := ClientId, username := Username}, Reason, _Env)
    when is_atom(Reason) ->
    Params = [{action, client_disconnected},
              {client_id, ClientId},
              {username, Username},
              {reason, Reason}],
    send_http_request(Params),
    ok;
on_client_disconnected(_, Reason, _Env) ->
    ?LOG(error, "Client disconnected, cannot encode reason: ~p", [Reason]),
    ok.

%%--------------------------------------------------------------------
%% Client subscribe
%%--------------------------------------------------------------------

on_client_subscribe(#{client_id := ClientId, username := Username}, TopicTable, {Filter}) ->
    lists:foreach(fun({Topic, Opts}) ->
      with_filter(
        fun() ->
          Params = [{action, client_subscribe},
                    {client_id, ClientId},
                    {username, Username},
                    {topic, Topic},
                    {opts, Opts}],
          send_http_request(Params)
        end, Topic, Filter)
    end, TopicTable).

%%--------------------------------------------------------------------
%% Client unsubscribe
%%--------------------------------------------------------------------

on_client_unsubscribe(#{client_id := ClientId, username := Username}, TopicTable, {Filter}) ->
    lists:foreach(fun({Topic, Opts}) ->
      with_filter(
        fun() ->
          Params = [{action, client_unsubscribe},
                    {client_id, ClientId},
                    {username, Username},
                    {topic, Topic},
                    {opts, Opts}],
          send_http_request(Params)
        end, Topic, Filter)
    end, TopicTable).

%%--------------------------------------------------------------------
%% Session created
%%--------------------------------------------------------------------

on_session_created(#{client_id := ClientId}, SessInfo, _Env) ->
    Params = [{action, session_created},
              {client_id, ClientId},
              {username, proplists:get_value(username, SessInfo)}],
    send_http_request(Params),
    ok.

%%--------------------------------------------------------------------
%% Session subscribed
%%--------------------------------------------------------------------

on_session_subscribed(#{client_id := ClientId}, Topic, Opts, {Filter}) ->
    with_filter(
      fun() ->
        Params = [{action, session_subscribed},
                  {client_id, ClientId},
                  {topic, Topic},
                  {opts, Opts}],
        send_http_request(Params)
      end, Topic, Filter).

%%--------------------------------------------------------------------
%% Session unsubscribed
%%--------------------------------------------------------------------

on_session_unsubscribed(#{client_id := ClientId}, Topic, _Opts, {Filter}) ->
    with_filter(
      fun() ->
        Params = [{action, session_unsubscribed},
                  {client_id, ClientId},
                  {topic, Topic}],
        send_http_request(Params)
      end, Topic, Filter).

%%--------------------------------------------------------------------
%% Session terminated
%%--------------------------------------------------------------------

on_session_terminated(Info, {shutdown, Reason}, Env) when is_atom(Reason) ->
    on_session_terminated(Info, Reason, Env);
on_session_terminated(#{client_id := ClientId}, Reason, _Env) when is_atom(Reason) ->
    Params = [{action, session_terminated},
              {client_id, ClientId},
              {reason, Reason}],
    send_http_request(Params),
    ok;
on_session_terminated(#{}, Reason, _Env) ->
    ?LOG(error, "Session terminated, cannot encode the reason: ~p", [Reason]),
    ok.

%%--------------------------------------------------------------------
%% Message publish
%%--------------------------------------------------------------------

on_message_publish(Message = #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    {ok, Message};
on_message_publish(Message = #message{topic = Topic, flags = #{retain := Retain}}, {Filter}) ->
    with_filter(
      fun() ->
        ?LOG(error, "From: ~p", [Message#message.from]),
        ?LOG(error, "Headers: ~p", [Message#message.headers]),

        try
            ?LOG(error, "Username: ~p", [maps:get("username", Message#message.headers)])
        catch
            Exception:Reason -> {caught, Exception, Reason}
        end,


        {FromClientId, FromUsername} = format_from(Message),
        ?LOG(error, "From => ~p", [FromClientId]),
        ?LOG(error, "Headers => ~p", [FromUsername]),
        Params = [{action, message_publish},
                  {from_client_id, FromClientId},
                  {from_username, FromUsername},
                  {topic, Message#message.topic},
                  {qos, Message#message.qos},
                  {retain, Retain},
                  {payload, Message#message.payload},
                  {ts, emqx_time:now_secs(Message#message.timestamp)}],
        send_http_request(Params),
        {ok, Message}
      end, Message, Topic, Filter).

%%--------------------------------------------------------------------
%% Message delivered
%%--------------------------------------------------------------------

on_message_delivered(#{client_id := ClientId, username := Username}, Message = #message{topic = Topic, flags = #{retain := Retain}}, {Filter}) ->
  with_filter(
    fun() ->
      {FromClientId, FromUsername} = format_from(Message),
      Params = [{action, message_delivered},
                {client_id, ClientId},
                {username, Username},
                {from_client_id, FromClientId},
                {from_username, FromUsername},
                {topic, Message#message.topic},
                {qos, Message#message.qos},
                {retain, Retain},
                {payload, Message#message.payload},
                {ts, emqx_time:now_secs(Message#message.timestamp)}],
      send_http_request(Params)
    end, Topic, Filter).

%%--------------------------------------------------------------------
%% Message acked
%%--------------------------------------------------------------------

on_message_acked(#{client_id := ClientId}, Message = #message{topic = Topic, flags = #{retain := Retain}}, {Filter}) ->
    with_filter(
      fun() ->
        {FromClientId, FromUsername} = format_from(Message),
        Params = [{action, message_acked},
                  {client_id, ClientId},
                  {from_client_id, FromClientId},
                  {from_username, FromUsername},
                  {topic, Message#message.topic},
                  {qos, Message#message.qos},
                  {retain, Retain},
                  {payload, Message#message.payload},
                  {ts, emqx_time:now_secs(Message#message.timestamp)}],
        send_http_request(Params)
      end, Topic, Filter).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

send_http_request(Params) ->
    Params1 = jsx:encode(Params),
    Url = application:get_env(?APP, url, "http://127.0.0.1"),
    ?LOG(debug, "Url:~p, params:~s", [Url, Params1]),
    case request_(post, {Url, [], "application/json", Params1}, [{timeout, 5000}], [], 0) of
        {ok, _} -> ok;
        {error, Reason} ->
            ?LOG(error, "HTTP request error: ~p", [Reason]), ok %% TODO: return ok?
    end.

request_(Method, Req, HTTPOpts, Opts, Times) ->
    %% Resend request, when TCP closed by remotely
    case httpc:request(Method, Req, HTTPOpts, Opts) of
        {error, socket_closed_remotely} when Times < 3 ->
            timer:sleep(trunc(math:pow(10, Times))),
            request_(Method, Req, HTTPOpts, Opts, Times+1);
        Other -> Other
    end.

parse_rule(Rules) ->
    parse_rule(Rules, []).
parse_rule([], Acc) ->
    lists:reverse(Acc);
parse_rule([{Rule, Conf} | Rules], Acc) ->
    Params = jsx:decode(iolist_to_binary(Conf)),
    Action = proplists:get_value(<<"action">>, Params),
    Filter = proplists:get_value(<<"topic">>, Params),
    parse_rule(Rules, [{list_to_atom(Rule), Action, Filter} | Acc]).

with_filter(Fun, _, undefined) ->
    Fun(), ok;
with_filter(Fun, Topic, Filter) ->
    case emqx_topic:match(Topic, Filter) of
        true  -> Fun(), ok;
        false -> ok
    end.

with_filter(Fun, _, _, undefined) ->
    Fun();
with_filter(Fun, Msg, Topic, Filter) ->
    case emqx_topic:match(Topic, Filter) of
        true  -> Fun();
        false -> {ok, Msg}
    end.

format_from(Message = #message{from = From, headers = #{}}) ->
    ?LOG(error, "From data: ~p", [From]),
    {a2b(From), a2b(From)};
format_from(#message{from = ClientId, headers = #{username := Username}}) ->
    {a2b(ClientId), a2b(Username)}.

a2b(A) when is_atom(A) -> erlang:atom_to_binary(A, utf8);
a2b(A) -> A.

load_(Hook, Fun, Filter, Params) ->
    case Hook of
        'client.connected'    -> emqx:hook(Hook, fun ?MODULE:Fun/4, [Params]);
        'client.disconnected' -> emqx:hook(Hook, fun ?MODULE:Fun/3, [Params]);
        'client.subscribe'    -> emqx:hook(Hook, fun ?MODULE:Fun/3, [Params]);
        'client.unsubscribe'  -> emqx:hook(Hook, fun ?MODULE:Fun/3, [Params]);
        'session.created'     -> emqx:hook(Hook, fun ?MODULE:Fun/3, [Params]);
        'session.subscribed'  -> emqx:hook(Hook, fun ?MODULE:Fun/4, [Params]);
        'session.unsubscribed'-> emqx:hook(Hook, fun ?MODULE:Fun/4, [Params]);
        'session.terminated'  -> emqx:hook(Hook, fun ?MODULE:Fun/3, [Params]);
        'message.publish'     -> emqx:hook(Hook, fun ?MODULE:Fun/2, [Params]);
        'message.acked'       -> emqx:hook(Hook, fun ?MODULE:Fun/3, [Params]);
        'message.delivered'   -> emqx:hook(Hook, fun ?MODULE:Fun/3, [Params])
    end.

unload_(Hook, Fun, Filter) ->
    case Hook of
        'client.connected'    -> emqx:unhook(Hook, fun ?MODULE:Fun/4);
        'client.disconnected' -> emqx:unhook(Hook, fun ?MODULE:Fun/3);
        'client.subscribe'    -> emqx:unhook(Hook, fun ?MODULE:Fun/3);
        'client.unsubscribe'  -> emqx:unhook(Hook, fun ?MODULE:Fun/3);
        'session.created'     -> emqx:unhook(Hook, fun ?MODULE:Fun/3);
        'session.subscribed'  -> emqx:unhook(Hook, fun ?MODULE:Fun/4);
        'session.unsubscribed'-> emqx:unhook(Hook, fun ?MODULE:Fun/4);
        'session.terminated'  -> emqx:unhook(Hook, fun ?MODULE:Fun/3);
        'message.publish'     -> emqx:unhook(Hook, fun ?MODULE:Fun/2);
        'message.acked'       -> emqx:unhook(Hook, fun ?MODULE:Fun/3);
        'message.delivered'   -> emqx:unhook(Hook, fun ?MODULE:Fun/3)
    end.

