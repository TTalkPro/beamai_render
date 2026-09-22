%%%-------------------------------------------------------------------
%%% @doc YAML front matter: a `---' block at the very start of the document,
%%% closed by `---' or `...', that renders as nothing.
%%%
%%% Port of markdig's YamlFrontMatter extension. The opener only counts
%%% when a closing fence exists somewhere below it, which is why the block
%%% start scans the rest of the document. Option: allow_in_middle (false).
%%%
%%% Block kind: yaml_front_matter, a leaf with the lines between the fences.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_yaml).

-behaviour(beamai_markdown_block_kind).

-include("beamai_markdown.hrl").

-export([setup/2, start/1, setup_html/1, render_html/2]).
-export([continue/2, finalize/2, can_contain/2, accepts_lines/1, after_line/2,
         blank_line_ignored/1]).

-spec setup(map(), map()) -> map().
setup(Pipe0, Opts) ->
    Pipe1 = beamai_markdown_pipeline:insert_before(
              Pipe0, block_parsers, thematic_break,
              #{name => yaml_front_matter, module => ?MODULE, function => start, chars => [$-],
                opts => Opts}),
    Pipe2 = beamai_markdown_pipeline:add_block_kind(Pipe1, yaml_front_matter, ?MODULE),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe2, html, #{name => yaml_front_matter, module => ?MODULE, function => setup_html}).

-spec start(#bp{}) -> {leaf, #bp{}} | none.
start(#bp{indented = false, line_start = LS, source = Src, line = Line, offset = 0} = Bp) ->
    Opts = case beamai_markdown_pipeline:find(Bp#bp.pipe, block_parsers, yaml_front_matter) of
               #{opts := O} -> O;
               _ -> #{}
           end,
    case (LS =:= 0 orelse maps:get(allow_in_middle, Opts, false))
        andalso is_fence(Line, $-) andalso has_closing(Src, LS + byte_size(Line)) of
        false -> none;
        true ->
            B = beamai_markdown_block:new_block(yaml_front_matter, Bp, 0),
            Bp1 = beamai_markdown_block:add_child(Bp, B),
            %% The opening fence is not content.
            {done, beamai_markdown_block:advance_offset(Bp1, byte_size(Line), false)}
    end;
start(_) -> none.

%% Exactly three of C, then only spaces.
is_fence(Line, C) ->
    N = beamai_markdown_scan:count_char(Line, 0, C),
    N =:= 3 andalso beamai_markdown_scan:is_blank(binary:part(Line, 3, byte_size(Line) - 3)).

%% A later line that is exactly --- or ... (plus trailing whitespace).
has_closing(Src, P) when P >= byte_size(Src) -> false;
has_closing(Src, P) ->
    case binary:at(Src, P) of
        $\n -> line_is_closing(Src, P + 1) orelse has_closing(Src, P + 1);
        _ -> has_closing(Src, P + 1)
    end.

line_is_closing(Src, P) ->
    End = case beamai_markdown_scan:find(Src, P, <<"\n">>) of
              none -> byte_size(Src);
              I -> I
          end,
    Line = string:trim(binary:part(Src, P, End - P), trailing, "\r"),
    is_fence(Line, $-) orelse is_fence(Line, $.).

-spec continue(beamai_markdown_block(), #bp{}) ->
          {match, #bp{}} | {match, beamai_markdown_block(), #bp{}} | nomatch
        | {close, beamai_markdown_block(), #bp{}}.
continue(B, #bp{indented = false, line = Line, next_nonspace = 0} = Bp) ->
    case is_fence(Line, $-) orelse is_fence(Line, $.) of
        true ->
            {close, B#{closed => true}, Bp};
        false -> {match, Bp}
    end;
continue(_, Bp) -> {match, Bp}.

-spec finalize(beamai_markdown_block(), #bp{}) -> {[beamai_markdown_block()], #bp{}}.
finalize(B, Bp) -> {[B], Bp}.

-spec can_contain(beamai_markdown_block(), atom()) -> boolean().
can_contain(_, _) -> false.

-spec accepts_lines(beamai_markdown_block()) -> boolean().
accepts_lines(_) -> true.

-spec after_line(beamai_markdown_block(), #bp{}) -> #bp{}.
after_line(_, Bp) -> Bp.

-spec blank_line_ignored(beamai_markdown_block()) -> boolean().
blank_line_ignored(_) -> true.

-spec setup_html(map()) -> map().
setup_html(R) ->
    beamai_markdown_renderer:set_renderer(R, yaml_front_matter, {?MODULE, render_html}).

%% Front matter is metadata: it renders as nothing.
-spec render_html(map(), beamai_markdown_block()) -> map().
render_html(R, _) -> R.
