%%%-------------------------------------------------------------------
%%% @doc JIRA links: `PROJ-123' becomes a link to an issue tracker.
%%%
%%% Options: base_url (required), base_path (<<"/browse">>),
%%% open_in_new_window (true). The reference must be preceded by `(' or
%%% whitespace and followed by `)' or whitespace.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_jira_links).

-include("beamai_markdown.hrl").

-export([setup/2, match/1]).

-spec setup(map(), map()) -> map().
setup(Pipe, Opts) ->
    Base = string:trim(unicode:characters_to_binary(maps:get(base_url, Opts)), trailing, "/"),
    Path = string:trim(unicode:characters_to_binary(maps:get(base_path, Opts, <<"/browse">>)), both, "/"),
    Entry = #{name => jira_link, module => ?MODULE, function => match, chars => lists:seq($A, $Z),
              opts => Opts#{url => <<Base/binary, "/", Path/binary>>}},
    beamai_markdown_pipeline:insert_before(
      beamai_markdown_pipeline:remove(Pipe, inline_parsers, jira_link), inline_parsers, link, Entry).

-spec match(#ip{}) -> {ok, #ip{}} | none.
match(#ip{src = Src, pos = P} = Ip) ->
    Prev = beamai_markdown_char:prev(Src, P),
    case Prev =:= ?NUL orelse Prev =:= $( orelse beamai_markdown_char:is_whitespace(Prev) of
        false -> none;
        true ->
            KeyEnd = key_end(Src, P),
            case beamai_markdown_char:at(Src, KeyEnd) =:= $- andalso
                beamai_markdown_char:is_digit(beamai_markdown_char:at(Src, KeyEnd + 1)) of
                false -> none;
                true ->
                    IssueEnd = digits_end(Src, KeyEnd + 1),
                    After = beamai_markdown_char:at(Src, IssueEnd),
                    case (After =:= ?NUL andalso IssueEnd >= byte_size(Src)) orelse After =:= $)
                        orelse beamai_markdown_char:is_whitespace(After) of
                        false -> none;
                        true ->
                            Label = binary:part(Src, P, IssueEnd - P),
                            #{opts := Opts} = beamai_markdown_pipeline:find(Ip#ip.pipe, inline_parsers, jira_link),
                            Url = <<(maps:get(url, Opts))/binary, "/", Label/binary>>,
                            Node0 = #{k => link, url => Url, image => false, jira => true,
                                      project => binary:part(Src, P, KeyEnd - P),
                                      issue => binary:part(Src, KeyEnd + 1, IssueEnd - KeyEnd - 1),
                                      children => [#{k => text, v => Label}]},
                            Node = case maps:get(open_in_new_window, Opts, true) of
                                       true -> beamai_markdown_attrs:add_property(Node0, <<"target">>, <<"_blank">>);
                                       false -> Node0
                                   end,
                            {ok, beamai_markdown_inline:push(Ip#ip{pos = IssueEnd}, Node)}
                    end
            end
    end.

%% Upper-case letters and digits (the trigger guarantees a letter first).
key_end(Src, P) ->
    C = beamai_markdown_char:at(Src, P),
    case (C >= $A andalso C =< $Z) orelse beamai_markdown_char:is_digit(C) of
        true -> key_end(Src, P + 1);
        false -> P
    end.

digits_end(Src, P) ->
    case beamai_markdown_char:is_digit(beamai_markdown_char:at(Src, P)) of
        true -> digits_end(Src, P + 1);
        false -> P
    end.
