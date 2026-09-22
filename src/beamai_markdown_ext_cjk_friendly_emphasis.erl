%%%-------------------------------------------------------------------
%%% @doc CJK-friendly emphasis: CJK characters count as punctuation in the
%%% flanking rules, so `**这个**吗' can close. See
%%% beamai_markdown_char:flanking_cjk/3.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_cjk_friendly_emphasis).

-export([setup/2]).

-spec setup(map(), map()) -> map().
setup(Pipe, _Opts) -> beamai_markdown_pipeline:set(Pipe, cjk_friendly, true).
