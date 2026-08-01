%% The Erlang side of glyde/internal/websocket/erlang. Coercion only: framing,
%% handshake and stream are Gleam.
%%
%% ssl answers with a bare ok or a reason term, and can raise instead of either.
%% The two reasons a caller acts on, a closed peer and a timeout, are named here
%% so Gleam can match them; the rest arrive rendered, and so does a raise. Every
%% ssl call this library makes goes through this module, so no ssl call can
%% raise into Gleam.

-module(glyde_websocket_ffi).

-export([connect/4, send/2, recv/2, close/1]).

%% The option list is built in Gleam, where each constructor is already the term
%% ssl:connect wants.
connect(Host, Port, Options, Timeout) ->
    try ssl:connect(Host, Port, Options, Timeout) of
        {ok, Socket} ->
            {ok, Socket};
        {error, Reason} ->
            {error, trouble(Reason)}
    catch
        Class:Reason:Stack ->
            {error, raised(Class, Reason, Stack)}
    end.

send(Socket, Data) ->
    try ssl:send(Socket, Data) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, trouble(Reason)}
    catch
        Class:Reason:Stack ->
            {error, raised(Class, Reason, Stack)}
    end.

%% Length 0 on a passive binary socket means whatever has arrived, which is what
%% a stream wants: the framing decides where a frame ends, not the read.
recv(Socket, Timeout) ->
    try ssl:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            {ok, Data};
        {error, Reason} ->
            {error, trouble(Reason)}
    catch
        Class:Reason:Stack ->
            {error, raised(Class, Reason, Stack)}
    end.

%% Nothing reads the answer, since the socket is going away whatever it says.
%% It is here because a teardown raise would otherwise unwind through a Gleam
%% function that has no way to report one.
close(Socket) ->
    try ssl:close(Socket) of
        _ ->
            nil
    catch
        _:_ ->
            nil
    end.

trouble(closed) ->
    hangup;
trouble(timeout) ->
    stalled;
trouble(Reason) ->
    {broken, glyde_term_ffi:describe(Reason)}.

%% A raise is a Trouble like any other, so a caller never has to think about
%% which ssl failures come back and which unwind.
raised(Class, Reason, Stack) ->
    {raised, glyde_term_ffi:describe(Class, Reason, Stack)}.
