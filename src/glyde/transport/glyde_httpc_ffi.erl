%% The Erlang side of glyde/transport/erlang. One function: run something and
%% turn a raise into a value.
%%
%% gleam_httpc's normalise_error/1 calls erlang:error/1 for any httpc failure it
%% has not modelled, so a DNS answer it does not recognise would take the whole
%% OS process down. The dial is guarded the same way: public_key:cacerts_get
%% raises on a host with no CA store. glyde has one long-lived gateway session
%% in that process.

-module(glyde_httpc_ffi).

-export([rescue/1]).

rescue(Attempt) ->
    try Attempt() of
        Result -> {ok, Result}
    catch
        Class:Reason:Stack -> {error, glyde_term_ffi:describe(Class, Reason, Stack)}
    end.
