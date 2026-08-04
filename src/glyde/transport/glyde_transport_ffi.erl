%% The Erlang side of glyde/transport/erlang. One function: run something and
%% turn a raise into a value. Guards both the websocket dial and the REST send:
%% public_key:cacerts_get raises on a host with no CA store, and gleam_httpc's
%% normalise_error/1 calls erlang:error/1 for any httpc failure it has not
%% modelled. Either would take the whole OS process down, and the one long-lived
%% gateway session with it.

-module(glyde_transport_ffi).

-export([rescue/1]).

rescue(Attempt) ->
    try Attempt() of
        Result -> {ok, Result}
    catch
        Class:Reason:Stack -> {error, glyde_term_ffi:describe(Class, Reason, Stack)}
    end.
