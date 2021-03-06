:- module(spotify, [access_token/2, run_curl/2, playlist_to_csv/3, run_curl/4,
                    retrieve_all/2, retrieve_all/4, playlist/2, playlist_track/2,
                    track_name/2, track_artists/2, track_info/2, playlist_info/2,
                    playlist_track_info/3, search/2, search/3, search/4, search/5,
                    search_info/3, search_info/5]).

:- use_module(library(clpfd)).
:- use_module(library(filesex)).
:- use_module(library(achelois)).
:- use_module(library(http/json)).
:- use_module(library(url)).

timestamp(Timestamp) :-
    get_time(Temp),
    Timestamp is round(Temp).

encoded_auth(Auth) :-
    client_id(ClientId),
    client_secret(ClientSecret),
    atomic_list_concat([ClientId, ClientSecret], ':', AuthStr),
    base64(AuthStr, AuthStr64),
    atom_concat('Authorization: Basic ', AuthStr64, Auth).

request_new_access_token(token(AccessToken, TokenType, ExpireTime)) :-
    timestamp(Now),
    encoded_auth(Auth),
    run_curl(_, [auth(Auth), method(post), data('grant_type=client_credentials'), url('https://accounts.spotify.com/api/token')], _, JSON),
    JSON = json(['access_token'=AccessToken, 'token_type'=TokenType, 'expires_in'=ExpireOffset|_]),
    ExpireTime #= Now + ExpireOffset.

access_token(Token, NewToken) :-
    Token = token(_AccessToken, _TokenType, ExpireTime),
    timestamp(Timestamp),

    (
        ( var(ExpireTime); ExpireTime #=< Timestamp) ->
            request_new_access_token(NewToken);

        ExpireTime #> Timestamp -> NewToken = Token
    ).

access_token_auth(token(AccessToken, _TokenType, _ExpireTime), AuthStr) :-
    atom_concat('Authorization: Bearer ', AccessToken, AuthStr).

select_or_default(X, Xs, NewXs, Default) :-
    select(X, Xs, NewXs) -> true;
    X = Default, NewXs = Xs.

add_params(Url, Params, BuiltUrl) :-
    parse_url(Url, Attributes),
    select_or_default(search(CurParams), Attributes, Temp, search([])),
    append(CurParams, Params, AllParams),
    parse_url(BuiltUrl, [search(AllParams) | Temp]).

build_curl_option(endpoint(Endpoint), Options) :-
    build_curl_option(endpoint(Endpoint, []), Options).
build_curl_option(endpoint(Endpoint, Params), [BuiltUrl]) :-
    atom_concat('https://api.spotify.com/v1/', Endpoint, Url),
    add_params(Url, Params, BuiltUrl).
build_curl_option(url(Url), Options) :-
    build_curl_option(url(Url, []), Options).
build_curl_option(url(Url, Params), [BuiltUrl]) :-
    add_params(Url, Params, BuiltUrl).
build_curl_option(method(Method), ['-X', MethodStr]) :-
    upcase_atom(Method, MethodStr).
build_curl_option(data(Data), ['-d', Data]).
build_curl_option(silent, ['-s']).
build_curl_option(auth(Auth), ['-H', Auth]).

with_option(Option, Options, [Option|Temp]) :-
    Option =.. [F|Params],
    length(Params, L),
    length(NewParams, L),
    VarOption =.. [F|NewParams],

    (
        select(VarOption, Options, Temp) -> true;
        Temp = Options
    ).

add_default(Option, Options, NewOptions) :-
    Option =.. [F|Params],
    length(Params, L),
    length(NewParams, L),
    VarOption =.. [F|NewParams],

    (
        member(VarOption, Options) -> NewOptions = Options;
        NewOptions = [Option|Options]
    ).

add_defaults(AllDefaults, Options, NewOptions) :-
    foldl(add_default, AllDefaults, Options, NewOptions).
add_curl_defaults(Token, Options, NewToken, NewOptions) :-
    Defaults = [silent],

    (
        not(member(auth(_), Options)) ->
            access_token(Token, NewToken),
            access_token_auth(NewToken, Auth),
            append([auth(Auth)], Defaults, AllDefaults);

        Token = NewToken, AllDefaults = Defaults
    ),

    add_defaults(AllDefaults, Options, NewOptions).

curl_options(Token, Options, NewToken, CurlOptions) :-
    add_curl_defaults(Token, Options, NewToken, AllOptions),
    maplist(build_curl_option, AllOptions, Temp),
    flatten(Temp, CurlOptions).

run_curl(Options, Response) :- run_curl(_, Options, _, Response).
run_curl(Token, Options, NewToken, Response) :-
    curl_options(Token, Options, NewToken, CurlOptions),
    process(path(curl), CurlOptions, [output(Output)]),
    catch(atom_json_term(Output, Response, []), _Error, Response = atom(Output)).

retrieve_all(Options, Result) :- retrieve_all(_, Options, _, Result).
retrieve_all(Token, Options, NewToken, Result) :-
    run_curl(Token, Options, TempToken, Response),

    (
        Response = json(JSON) ->
        (
            member(next='@'(null), JSON), member(items=AllItems, JSON) -> member(Result, AllItems);
            member(next=Url, JSON), member(items=Items, JSON) ->
                (
                    member(Result, Items);
                    with_option(url(Url), Options, NewOptions),
                    retrieve_all(TempToken, NewOptions, NewToken, Result)
                );
            Result = Response
        );
        Result = Response
    ).

playlist(User, Playlist) :-
    atomic_list_concat(['users', User, 'playlists'], '/', Endpoint),
    retrieve_all(_, [endpoint(Endpoint)], _, Playlist).

playlist_track(PlaylistId, Track) :-
    atomic_list_concat(['playlists', PlaylistId, 'tracks'], '/', Endpoint),
    retrieve_all(_, [endpoint(Endpoint)], _, json(T)),
    member(track=Track, T).

track_name(json(Track), Name) :-
    member(name=Name, Track).

track_artists(json(Track), ArtistNames) :-
    member(artists=Artists, Track),
    findall(Name, (member(json(Artist), Artists), member(name=Name, Artist)), ArtistNames).

track_info(Track, Name-Artists) :-
    track_name(Track, Name),
    track_artists(Track, Artists).

playlist_info(json(Playlist), Id-Name) :-
    member(id=Id, Playlist),
    member(name=Name, Playlist).

playlist_track_info(User, Id-Name, Info) :-
    playlist(User, Playlist),
    playlist_info(Playlist, Id-Name),
    playlist_track(Id, Track),
    track_info(Track, Info).

track_to_csv(Name-Artists, row(Name, ArtistsStr)) :-
    atomic_list_concat(Artists, ',', ArtistsStr).

% TODO: Would be very cool if we could make this bidirectional
% (e.g., read from a csv and create a playlist, or write a playlist from Spotify)
playlist_to_csv(User, Id-Name, Stream) :-
    forall(playlist_track_info(User, Id-Name, Track),
    (
        track_to_csv(Track, CsvRow),
        csv_write_stream(Stream, [CsvRow], [])
    )).

build_param(F, Name=Value) :-
    F =.. [Name, Value].

search_info(Type, Options, Result) :- search_info(Type, _, Options, _, Result).
search_info(track, Token, Options, NewToken, Result) :-
    search(track, Token, Options, NewToken, Track),
    track_info(Track, Result).

search(Options, Result) :- search(_, Options, _, Result).
search(Type, Options, Result) :- search(Type, _, Options, _, Result).
search(Token, Options, NewToken, Result) :-
    member(type(Type), Options) -> search(Type, Token, Options, NewToken, Result);

    search(track, Token, Options, NewToken, Result);
    search(album, Token, Options, NewToken, Result);
    search(artist, Token, Options, NewToken, Result);
    search(playlist, Token, Options, NewToken, Result).

search(Type, Token, Options, NewToken, Result) :-
    add_defaults([type(Type)], Options, AllOptions),
    member(type(ActualType), AllOptions),
    maplist(build_param, AllOptions, Params),

    search_inner(ActualType, Token, [endpoint('search', Params)], NewToken, Result).

search_inner(Type, Token, Options, NewToken, Result) :-
    run_curl(Token, Options, TempToken, json(Response)),
    atom_concat(Type, 's', TypeStr),
    member(TypeStr=json(JSON), Response),

    (
        member(next='@'(null), JSON), member(items=AllItems, JSON) -> member(Result, AllItems);
        member(next=Url, JSON), member(items=Items, JSON) ->
            (
                member(Result, Items);
                with_option(url(Url), Options, NewOptions),
                search_inner(Type, TempToken, NewOptions, NewToken, Result)
            );
        Result = Response
    ).

