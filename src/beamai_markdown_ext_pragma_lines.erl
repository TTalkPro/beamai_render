%%%-------------------------------------------------------------------
%%% @doc Pragma lines: every block gets `id="pragma-line-N"' (N its
%%% zero-based source line), so rendered HTML can be mapped back to the
%%% source. A block whose id is taken (by auto identifiers, say) gets an
%%% `<a id="pragma-line-N"></a>' anchor instead: inside a heading, or as an
%%% HTML block right before anything else.
%%%
%%% beamai_markdown:find_closest_line/2 is the other half.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_pragma_lines).

-include("beamai_markdown.hrl").

-export([setup/2, tag/3]).

-spec setup(map(), map()) -> map().
setup(Pipe, _Opts) ->
    beamai_markdown_pipeline:replace(
      Pipe, document_hooks, pragma_lines,
      #{name => pragma_lines, module => ?MODULE, function => tag}).

-spec tag(beamai_markdown_block(), map(), map()) -> beamai_markdown_block().
tag(#{children := Ch} = Doc, _Pipe, _Opts) ->
    Doc#{children => lists:append([block(C) || C <- Ch])}.

%% A block may become two (anchor block + itself).
block(#{k := K, line := Line} = B0) ->
    Id = <<"pragma-line-", (integer_to_binary(max(0, Line - 1)))/binary>>,
    {Before, B1} =
        case beamai_markdown_attrs:id(B0) of
            undefined -> {[], beamai_markdown_attrs:set_id(B0, Id)};
            _ ->
                Tag = <<"<a id=\"", Id/binary, "\"></a>">>,
                case B0 of
                    #{inlines := Inlines} when K =:= heading, Inlines =/= [] ->
                        {[], B0#{inlines => [#{k => html, v => Tag} | Inlines]}};
                    _ ->
                        Anchor = #{k => html_block, line => Line, col => 1, children => [],
                                   lines => [{Tag, Line, <<"\n">>}], html_type => 7},
                        {[Anchor], B0}
                end
        end,
    B2 = case B1 of
             #{children := Ch} when Ch =/= [] -> B1#{children => lists:append([block(C) || C <- Ch])};
             _ -> B1
         end,
    Before ++ [B2].
