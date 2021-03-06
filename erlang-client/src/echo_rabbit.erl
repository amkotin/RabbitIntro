-module(echo_rabbit).

-include_lib("rabbitmq_server/include/rabbit.hrl").
-include_lib("rabbitmq_server/include/rabbit_framing.hrl").
-include("amqp_client.hrl").
-compile([export_all]).

-record(publish, {q, x, routing_key, bind_key, payload,
                 mandatory = false, immediate = false}).

%% The latch constant defines how many processes are spawned in order
%% to run certain functionality in parallel. It follows the standard
%% countdown latch pattern.
-define(Latch, 100).

%% The wait constant defines how long a consumer waits before it
%% unsubscribes
-define(Wait, 200).


new_connection() ->
    lib_amqp:start_connection("localhost").


consume() ->
    io:format("** starting ...~n"),
    Connection = new_connection(),
    io:format("** Connection started~n"),
    Channel = lib_amqp:start_channel(Connection),
    io:format("** Channel started~n"),
    X = uuid(),
    lib_amqp:declare_exchange(Channel, X, <<"topic">>),
    io:format("** Exchange declared~n"),
    RoutingKey = uuid(),
    Parent = self(),
    [spawn(
        fun() ->
            consume_loop(Channel, X, RoutingKey, Parent, <<Tag:32>>) end) || Tag <- lists:seq(1, ?Latch)
    ],
    timer:sleep(?Latch * 20),
    lib_amqp:publish(Channel, X, RoutingKey, <<"foobar">>),
    latch_loop(?Latch),
    lib_amqp:teardown(Connection, Channel).

consume_loop(Channel, X, RoutingKey, Parent, Tag) ->
    Q = lib_amqp:declare_queue(Channel),
    lib_amqp:bind_queue(Channel, X, Q, RoutingKey),
    lib_amqp:subscribe(Channel, Q, self(), Tag),
    receive
        #'basic.consume_ok'{consumer_tag = Tag} -> ok
    end,
    receive
        {#'basic.deliver'{}, _Content} -> ok
    end,
    lib_amqp:unsubscribe(Channel, Tag),
    receive
        #'basic.cancel_ok'{consumer_tag = Tag} -> ok
    end,
    io:format("Content: ~s~n", [_Content]),
    Parent ! finished.



start() ->
    X = <<"x">>,
    Connection = new_connection(),
    Channel = lib_amqp:start_channel(Connection),
    lib_amqp:declare_exchange(Channel, X, <<"topic">>),
    Parent = self(),
    [spawn(
           fun() ->
                queue_exchange_binding(Channel, X, Parent, Tag) end)
            || Tag <- lists:seq(1, ?Latch)],
    latch_loop(?Latch),
    lib_amqp:delete_exchange(Channel, X),
    lib_amqp:teardown(Connection, Channel),
    ok.

queue_exchange_binding(Channel, X, Parent, Tag) ->
    receive
        nothing -> ok
    after (?Latch - Tag rem 7) * 10 ->
        ok
    end,
    Q = <<"a.b.c", Tag:32>>,
    Binding = <<"a.b.c.*">>,
    Q1 = lib_amqp:declare_queue(Channel, Q),
    io:format("QUEUE: ~s~n", [Q1]),
    lib_amqp:bind_queue(Channel, X, Q, Binding),
    lib_amqp:delete_queue(Channel, Q),
    Parent ! finished.


latch_loop(0) ->
    ok;

latch_loop(Latch) ->
    receive
        finished ->
            latch_loop(Latch - 1)
    after ?Latch * ?Wait ->
        exit(waited_too_long)
    end.

uuid() ->
    {A, B, C} = now(),
    <<A:32, B:32, C:32>>.
