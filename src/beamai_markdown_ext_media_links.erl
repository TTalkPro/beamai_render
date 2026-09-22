%%%-------------------------------------------------------------------
%%% @doc Media links: an image link to a known video host renders as an
%%% `<iframe>', and one to a media file (by extension) as `<video>' or
%%% `<audio>'. Everything else falls through to the ordinary image.
%%%
%%% A try-writer on the link renderer. Options: width (<<"500">>), height
%%% (<<"281">>), add_controls_property (true), class (<<>>), hosts (see
%%% default_hosts/0), extension_mime_types.
%%% @end
%%%-------------------------------------------------------------------
-module(beamai_markdown_ext_media_links).

-include("beamai_markdown.hrl").

-export([setup/2, setup_html/1, try_write/2, default_hosts/0, default_mime_types/0]).

-spec setup(map(), map()) -> map().
setup(Pipe0, Opts) ->
    Pipe1 = beamai_markdown_pipeline:set(Pipe0, media_options, Opts),
    beamai_markdown_pipeline:add_renderer_setup(
      Pipe1, html, #{name => media_links, module => ?MODULE, function => setup_html}).

-spec setup_html(map()) -> map().
setup_html(R) ->
    beamai_markdown_renderer:add_try_writer(R, link, {?MODULE, try_write}).

-spec try_write(map(), beamai_markdown_inline()) -> {ok, map()} | none.
try_write(R, #{k := link, image := true, url := Url0} = Link) ->
    Opts = maps:get(media_options, beamai_markdown_renderer:get(R, pipe), #{}),
    Url = case Url0 of
              <<"//", _/binary>> -> <<"https:", Url0/binary>>;
              _ -> Url0
          end,
    case split_url(Url) of
        {Host, Path, Query} ->
            case iframe(R, Link, Host, Path, Query, Opts) of
                {ok, _} = Ok -> Ok;
                none -> audio_video(R, Link, Path, Opts)
            end;
        none -> audio_video(R, Link, Url, Opts)
    end;
try_write(_, _) -> none.

%%%===================================================================
%%% URL bits
%%%===================================================================

split_url(Url) ->
    case binary:split(Url, <<"://">>) of
        [_, Rest] ->
            {Host, PathQ} = case binary:split(Rest, <<"/">>) of
                                [H, P] -> {H, <<"/", P/binary>>};
                                [H] -> {H, <<>>}
                            end,
            case Host of
                <<>> -> none;
                _ ->
                    case binary:split(PathQ, <<"?">>) of
                        [P1, Q] -> {Host, P1, Q};
                        [P1] -> {Host, P1, <<>>}
                    end
            end;
        _ -> none
    end.

query_param(Query, Name) ->
    Prefix = <<Name/binary, "=">>,
    N = byte_size(Prefix),
    case [V || <<P:N/binary, V/binary>> <- binary:split(Query, <<"&">>, [global]), P =:= Prefix] of
        [V | _] -> V;
        [] -> undefined
    end.

segments(Path) -> [S || S <- binary:split(Path, <<"/">>, [global]), S =/= <<>>].

prefix_ci(Prefix, Bin) ->
    N = byte_size(Prefix),
    byte_size(Bin) >= N andalso string:lowercase(binary:part(Bin, 0, N)) =:= string:lowercase(Prefix).

%%%===================================================================
%%% Hosts
%%%===================================================================

%% @doc [{HostPrefix, Fun(Host, Path, Query) -> Url | undefined, AllowFullscreen, Class}]
-spec default_hosts() -> [{binary(), fun((binary(), binary(), binary()) -> binary() | undefined), boolean(), binary()}].
default_hosts() ->
    [{<<"www.youtube.com">>,
      fun(_, Path, _) ->
              case prefix_ci(<<"/shorts/">>, Path) of
                  true -> youtube(hd_or(segments(binary:part(Path, 8, byte_size(Path) - 8))), undefined);
                  false -> undefined
              end
      end, true, <<"youtubeshort">>},
     {<<"www.youtube.com">>,
      fun(Host, Path, Query) ->
              Lower = string:lowercase(Path),
              case Lower =:= <<"/embed">> orelse prefix_ci(<<"/embed/">>, Path) of
                  true ->
                      case Query of
                          <<>> -> <<"https://", Host/binary, Path/binary>>;
                          _ -> <<"https://", Host/binary, Path/binary, "?", Query/binary>>
                      end;
                  false ->
                      case Lower =:= <<"/watch">> orelse prefix_ci(<<"/watch/">>, Path) of
                          true -> youtube(query_param(Query, <<"v">>), query_param(Query, <<"t">>));
                          false -> undefined
                      end
              end
      end, true, <<"youtube">>},
     {<<"youtu.be">>,
      fun(_, Path, Query) ->
              Id = case Path of <<"/", R/binary>> -> R; _ -> Path end,
              youtube(Id, query_param(Query, <<"t">>))
      end, true, <<"youtube">>},
     {<<"vimeo.com">>,
      fun(_, Path, _) ->
              case segments(Path) of
                  [] -> undefined;
                  Segs -> <<"https://player.vimeo.com/video/", (lists:last(Segs))/binary>>
              end
      end, true, <<"vimeo">>},
     {<<"music.yandex.ru">>,
      fun(_, Path, _) ->
              case segments(Path) of
                  [<<"album">>, Album, <<"track">>, Track | _] ->
                      <<"https://music.yandex.ru/iframe/#track/", Track/binary, "/", Album/binary, "/">>;
                  _ -> undefined
              end
      end, false, <<"yandex">>},
     {<<"ok.ru">>,
      fun(_, Path, _) ->
              case segments(Path) of
                  [] -> undefined;
                  Segs -> <<"https://ok.ru/videoembed/", (lists:last(Segs))/binary>>
              end
      end, true, <<"odnoklassniki">>}].

hd_or([]) -> undefined;
hd_or([H | _]) -> H.

youtube(undefined, _) -> undefined;
youtube(<<>>, _) -> undefined;
youtube(Id, T) when T =:= undefined; T =:= <<>> -> <<"https://www.youtube.com/embed/", Id/binary>>;
youtube(Id, T) -> <<"https://www.youtube.com/embed/", Id/binary, "?start=", T/binary>>.

-spec default_mime_types() -> [{binary(), binary()}].
default_mime_types() ->
    [{<<".3gp">>, <<"video/3gpp">>}, {<<".avi">>, <<"video/x-msvideo">>},
     {<<".flv">>, <<"video/x-flv">>}, {<<".h264">>, <<"video/h264">>},
     {<<".m4v">>, <<"video/x-m4v">>}, {<<".mov">>, <<"video/quicktime">>},
     {<<".mp4">>, <<"video/mp4">>}, {<<".mpeg">>, <<"video/mpeg">>},
     {<<".mpg">>, <<"video/mpeg">>}, {<<".ogv">>, <<"video/ogg">>},
     {<<".qt">>, <<"video/quicktime">>}, {<<".webm">>, <<"video/webm">>},
     {<<".wmv">>, <<"video/x-ms-wmv">>},
     {<<".aac">>, <<"audio/x-aac">>}, {<<".aif">>, <<"audio/x-aiff">>},
     {<<".m3u">>, <<"audio/x-mpegurl">>}, {<<".mid">>, <<"audio/midi">>},
     {<<".mp3">>, <<"audio/mpeg">>}, {<<".mp4a">>, <<"audio/mp4">>},
     {<<".oga">>, <<"audio/ogg">>}, {<<".ogg">>, <<"audio/ogg">>},
     {<<".wav">>, <<"audio/x-wav">>}, {<<".weba">>, <<"audio/webm">>},
     {<<".wma">>, <<"audio/x-ms-wma">>}].

%%%===================================================================
%%% Writing
%%%===================================================================

iframe(R, Link, Host, Path, Query, Opts) ->
    Hosts = maps:get(hosts, Opts, default_hosts()),
    Found = lists:foldl(fun(_, {ok, _} = Done) -> Done;
                           ({Prefix, Fun, Full, Class}, none) ->
                                case prefix_ci(Prefix, Host) of
                                    false -> none;
                                    true ->
                                        case Fun(Host, Path, Query) of
                                            U when is_binary(U), U =/= <<>> -> {ok, {U, Full, Class}};
                                            _ -> none
                                        end
                                end
                        end, none, Hosts),
    case Found of
        none -> none;
        {ok, {Url, AllowFull, Class}} ->
            A0 = beamai_markdown_attrs:attrs(Link),
            A1 = add_if_missing(A0, <<"width">>, maps:get(width, Opts, <<"500">>)),
            A2 = add_if_missing(A1, <<"height">>, maps:get(height, Opts, <<"281">>)),
            A3 = add_class(A2, maps:get(class, Opts, <<>>)),
            A4 = add_class(A3, Class),
            A5 = add_if_missing(A4, <<"frameborder">>, <<"0">>),
            A6 = case AllowFull of
                     true -> add_if_missing(A5, <<"allowfullscreen">>, <<>>);
                     false -> A5
                 end,
            R1 = beamai_markdown_html:write_escape_url(beamai_markdown_renderer:write(R, <<"<iframe src=\"">>), Url),
            R2 = beamai_markdown_html:write_attributes(beamai_markdown_renderer:write_raw(R1, <<"\"">>), #{k => x, attrs => A6}),
            {ok, beamai_markdown_renderer:write_raw(R2, <<"></iframe>">>)}
    end.

audio_video(R, #{url := Url} = Link, Path, Opts) ->
    case binary:matches(Path, <<".">>) of
        [] -> none;
        Ms ->
            {Dot, _} = lists:last(Ms),
            Ext = string:lowercase(binary:part(Path, Dot, byte_size(Path) - Dot)),
            case lists:keyfind(Ext, 1, maps:get(extension_mime_types, Opts, default_mime_types())) of
                false -> none;
                {_, Mime} ->
                    Audio = prefix_ci(<<"audio">>, Mime),
                    Tag = case Audio of true -> <<"audio">>; false -> <<"video">> end,
                    A0 = beamai_markdown_attrs:attrs(Link),
                    A1 = add_if_missing(A0, <<"width">>, maps:get(width, Opts, <<"500">>)),
                    A2 = case Audio of
                             true -> A1;
                             false -> add_if_missing(A1, <<"height">>, maps:get(height, Opts, <<"281">>))
                         end,
                    A3 = case maps:get(add_controls_property, Opts, true) of
                             true -> add_if_missing(A2, <<"controls">>, <<>>);
                             false -> A2
                         end,
                    A4 = add_class(A3, maps:get(class, Opts, <<>>)),
                    R1 = beamai_markdown_html:write_attributes(beamai_markdown_renderer:write(R, [<<"<">>, Tag]),
                                                               #{k => x, attrs => A4}),
                    {ok, beamai_markdown_renderer:write(
                           R1, [<<"><source type=\"">>, Mime, <<"\" src=\"">>, Url, <<"\"></source></">>, Tag, <<">">>])}
            end
    end.

add_if_missing(A, K, V) ->
    Props = maps:get(props, A, []),
    case lists:keymember(K, 1, Props) of
        true -> A;
        false -> A#{props => Props ++ [{K, V}]}
    end.

add_class(A, <<>>) -> A;
add_class(A, C) ->
    Cs = maps:get(classes, A, []),
    case lists:member(C, Cs) of
        true -> A;
        false -> A#{classes => Cs ++ [C]}
    end.
