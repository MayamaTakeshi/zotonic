%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2014 Marc Worrell
%% @doc Handle the OAuth redirect of the LinkedIn logon handshake.
%% See https://developer.linkedin.com/documents/authentication

%% Copyright 2014 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(controller_linkedin_redirect).
-author("Marc Worrell <marc@worrell.nl>").

-export([
    process/4,
    fetch_user_data/1,
    fetch_email_address/1
    ]).

-include_lib("zotonic_core/include/zotonic.hrl").

process(_Method, _AcceptedCT, _ProvidedCT, Context) ->
    QState = z_context:get_q(<<"state">>, Context),
    Context1 = z_context:reset_state_cookie(Context),
    case z_context:get_state_cookie(Context) of
        {ok, {QState, Args}} ->
            case z_context:get_q(<<"code">>, Context) of
                Code when is_binary(Code), Code =/= <<>> ->
                    access_token(fetch_access_token(Code, Context1), Args, Context1);
                undefined ->
                    Context2 = z_render:wire({script, [{script, "window.close();"}]}, Context1),
                    html_error(cancel, Context2)
            end;
        {ok, {SessionState, _}} ->
            lager:warning("LinkedIn OAuth redirect with state mismatch, expected ~p, got ~p",
                          [SessionState, QState]),
            Context2 = z_render:wire({script, [{script, "window.close();"}]}, Context1),
            html_error(wrong_secret, Context2);
        _ ->
            lager:warning("LinkedIn OAuth redirect with missing or illegal state cookie"),
            html_error(missing_secret, Context1)
    end.

access_token({ok, AccessToken, Expires}, Args, Context) ->
    Data = [
        {access_token, AccessToken},
        {expires, Expires}
    ],
    user_data(fetch_user_data(AccessToken), fetch_email_address(AccessToken), Data, Args, Context);
access_token({error, _Reason}, _Args, Context) ->
    html_error(access_token, Context).

user_data({ok, UserProps}, {ok, Email}, AccessData, Args, Context) ->
    Auth = auth_user(UserProps, Email, AccessData, Args, Context),
    do_auth_user(Auth, Context);
user_data({ok, UserProps}, {error, Reason}, _AccessData, _Args, Context) ->
    lager:error("No email address, error ~p for ~p", [Reason, UserProps]),
    html_error(service_user_data, Context);
user_data(_UserError, _EmailError, _AccessData, _Args, Context) ->
    html_error(service_user_data, Context).

do_auth_user(Auth, Context) ->
    case z_notifier:first(Auth, Context) of
        undefined ->
            % No handler for signups, or signup not accepted
            lager:warning("[linkedin] Undefined auth_user return for user with props ~p", [Auth]),
            html_error(auth_user_undefined, Context);
        {error, duplicate} ->
            lager:info("[linkedin] Duplicate connection for user with props ~p", [Auth]),
            html_error(duplicate, Context);
        {error, {duplicate_email, Email}} ->
            lager:info("[linkedin] User with email \"~s\" already exists", [Email]),
            html_error(duplicate_email, Email, Context);
        {error, signup_confirm} ->
            % We need a confirmation from the user before we add a new account
            html_error(signup_confirm, {auth, Auth}, Context);
        {error, _} = Err ->
            lager:warning("[linkedin] Error return ~p for user with props ~p", [Err, Auth]),
            html_error(auth_user_error, Context);
        {ok, Context1} ->
            html_ok(Context1)
    end.


html_ok(Context) ->
    Html = z_template:render("logon_service_done.tpl", [{service, "LinkedIn"} | z_context:get_all(Context)], Context),
    z_context:output(Html, Context).

html_error(Error, Context) ->
    html_error(Error, undefined, Context).

html_error(Error, What, Context) ->
    Vars = [
        {service, "LinkedIn"},
        {is_safari8problem, is_safari8problem(Context)},
        {what, What},
        {error, Error}
    ],
    Html = z_template:render("logon_service_error.tpl", Vars, Context),
    z_context:output(Html, Context).

%% @doc There is a problem here with Safari 8.0.x which (in its default setting) does not pass any
%%      cookies after the redirect from LinkedIn (and other OAuth redirects).
%%      See also this issue: https://github.com/drone/drone/issues/663#issuecomment-61565820
is_safari8problem(Context) ->
    Hs = m_req:get(headers, Context),
    HasCookies = proplists:is_defined(<<"cookie">>, Hs),
    UA = m_req:get(user_agent, Context),
    IsVersion8 = binary:match(UA, <<"Version/8.0.">>) =/= nomatch,
    IsSafari = binary:match(UA, <<"Safari/6">>) =/= nomatch,
    not HasCookies andalso IsVersion8 andalso IsSafari.


auth_user(#{<<"id">> := LinkedInUserId} = Profile, Email, AccessTokenData, Args, _Context) ->
    lager:debug("[linkedin] Authenticating ~p ~p", [LinkedInUserId, Profile]),
    PersonProps = [
        {title, iolist_to_binary([
                z_convert:to_binary(get_localized_value(<<"firstName">>, Profile)), " ",
                z_convert:to_binary(get_localized_value(<<"lastName">>, Profile))
            ])},
        {name_first, get_localized_value(<<"firstName">>, Profile)},
        {name_surname, get_localized_value(<<"lastName">>, Profile)},
        {summary, get_localized_value(<<"headline">>, Profile)},
        {email, Email}
    ],
    #auth_validated{
            service=linkedin,
            service_uid=LinkedInUserId,
            service_props=AccessTokenData,
            props=PersonProps,
            is_connect=z_convert:to_bool(proplists:get_value(<<"is_connect">>, Args))
        }.

get_localized_value(Prop, JSON) ->
    case maps:get(Prop, JSON, undefined) of
        Localized when is_map(Localized) ->
            case maps:get(<<"localized">>, Localized, undefined) of
                Locs when is_map(Locs) ->
                    [ {_, V} | _ ] = maps:to_list(Locs),
                    maps:get(<<"en_US">>, Locs, V);
                undefined ->
                    undefined
            end;
        Bin when is_binary(Bin) ->
            Bin;
        null ->
            undefined;
        undefined ->
            undefined
    end.

% Exchange the code for an access token
fetch_access_token(Code, Context) ->
    {AppId, AppSecret, _Scope} = mod_linkedin:get_config(Context),
    PK = z_context:get_q("pk", Context, []),
    RedirectUrl = z_context:abs_url(z_dispatcher:url_for(linkedin_redirect, [{pk,PK}], Context), Context),
    LinkedInUrl = "https://www.linkedin.com/uas/oauth2/accessToken",
    Body = iolist_to_binary([
            "grant_type=authorization_code",
            "&client_id=", z_url:url_encode(AppId),
            "&redirect_uri=", z_convert:to_list(z_url:url_encode(RedirectUrl)),
            "&client_secret=", z_url:url_encode(AppSecret),
            "&code=", z_url:url_encode(Code)
        ]),
    case httpc:request(post, {LinkedInUrl, [], "application/x-www-form-urlencoded", Body}, httpc_http_options(), httpc_options()) of
        {ok, {{_, 200, _}, _Headers, Payload}} ->
            #{
                <<"access_token">> := AccessToken,
                <<"expires_in">> := ExpiresIn
            } = z_json:decode(Payload),
            {ok, AccessToken, ExpiresIn};
        Other ->
            lager:error("[linkedin] error fetching access token [code ~p] ~p", [Code, Other]),
            {error, {http_error, LinkedInUrl, Other}}
    end.

% Given the access token, fetch data about the user
fetch_user_data(AccessToken) ->
    LinkedInUrl = "https://api.linkedin.com/v2/me"
                ++ "?oauth2_access_token=" ++ z_convert:to_list(AccessToken),
    case httpc:request(get, {LinkedInUrl, []}, httpc_http_options(), httpc_options()) of
        {ok, {{_, 200, _}, _Headers, Payload}} ->
            {ok, z_json:decode(Payload)};
        {ok, {{_, 401, _}, _Headers, Payload}} = Other ->
            lager:error("[linkedin] 401 error fetching user data [token ~p] will not retry ~p", [AccessToken, Payload]),
            {error, {http_error, LinkedInUrl, Other}};
        Other ->
            lager:error("[linkedin] error fetching user data [token ~p] ~p", [AccessToken, Other]),
            {error, {http_error, LinkedInUrl, Other}}
    end.


% [{<<"elements">>,
%       [{struct,[{<<"handle">>,<<"urn:li:emailAddress:109707987">>},
%                 {<<"handle~">>,
%                  {struct,[{<<"emailAddress">>,<<"piet@example.com">>}]}}]}]}]}
fetch_email_address(AccessToken) ->
    LinkedInUrl = "https://api.linkedin.com/v2/emailAddress?q=members&projection=(elements*(handle~))"
                ++ "&oauth2_access_token=" ++ z_convert:to_list(AccessToken),
    case httpc:request(get, {LinkedInUrl, []}, httpc_http_options(), httpc_options()) of
        {ok, {{_, 200, _}, _Headers, Payload}} ->
            Props = z_json:decode(Payload),
            case maps:get(<<"elements">>, Props, []) of
                [ Hs | _ ] when is_map(Hs) ->
                    case maps:get(<<"handle~">>, Hs, undefined) of
                        Es when is_map(Es) ->
                            case maps:get(<<"emailAddress">>, Es, undefined) of
                                Email when is_binary(Email) ->
                                    {ok, Email};
                                _ ->
                                    {error, noemail}
                            end;
                        _ ->
                            {error, noemail}
                    end;
                _ ->
                    {error, noemail}
            end;
        {ok, {{_, 401, _}, _Headers, Payload}} = Other ->
            lager:error("[linkedin] 401 error fetching user email [token ~p] will not retry ~p", [AccessToken, Payload]),
            {error, {http_error, LinkedInUrl, Other}};
        Other ->
            lager:error("[linkedin] error fetching user email [token ~p] ~p", [AccessToken, Other]),
            {error, {http_error, LinkedInUrl, Other}}
    end.

httpc_options() ->
    [
        {sync, true},
        {body_format, binary}
    ].

httpc_http_options() ->
    [
        {timeout, 10000},
        {connect_timeout, 10000},
        {autoredirect, true},
        {relaxed, true}
    ].

