%% Rendering an Erlang term as a Gleam string. A reason term is the one thing
%% Gleam cannot print, so every FFI shim that has to name a failure comes here
%% rather than growing its own copy.

-module(glyde_term_ffi).

-export([describe/1, describe/3]).

%% ~0p keeps a reason on one line, so it can go straight into an error string.
describe(Term) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Term])).

%% A raise, with the frame it came from: this is the only record of it, because
%% a rescued raise never reaches the VM's crash report. ~0P caps the reason at
%% depth 12 so one huge term cannot swallow the line.
%%
%% An empty stack is possible, erlang:raise/3 takes any list.
describe(Class, Reason, [Frame | _]) ->
    unicode:characters_to_binary(
        io_lib:format("~s: ~0P at ~0p", [Class, Reason, 12, Frame])
    );
describe(Class, Reason, []) ->
    unicode:characters_to_binary(io_lib:format("~s: ~0P", [Class, Reason, 12])).
