%%%-------------------------------------------------------------------
%%% @doc Every soft line break is a hard one (renders as `<br />').
%%% The flag lives on the pipeline and the newline parser reads it, so
%%% every renderer sees hard breaks, as in markdig.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_hardline_breaks).

-export([setup/2]).

-spec setup(map(), map()) -> map().
setup(Pipe, _Opts) -> beamai_markdown_pipeline:set(Pipe, soft_as_hard, true).
