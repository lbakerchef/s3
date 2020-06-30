%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% Amazon Simple Storage Service (S3)
%% Copyright 2010 Brian Buchanan. All Rights Reserved.
%% Copyright 2012 Opscode, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(mini_s3).

-behavior(application).

-export([
         new/3,
         new/4,
         new/5,
         create_bucket/3,
         create_bucket/4,
         delete_bucket/1,
         delete_bucket/2,
         get_bucket_attribute/2,
         get_bucket_attribute/3,
         list_buckets/1,
         set_bucket_attribute/3,
         set_bucket_attribute/4,
         list_objects/2,
         list_objects/3,
         list_object_versions/2,
         list_object_versions/3,
         copy_object/5,
         copy_object/6,
         delete_object/2,
         delete_object/3,
         delete_object_version/3,
         delete_object_version/4,
         get_object/3,
         get_object/4,
         get_object_acl/2,
         get_object_acl/3,
         get_object_acl/4,
         get_object_torrent/2,
         get_object_torrent/3,
         get_object_metadata/4,
         get_host_toggleport/2,
         get_url_noport/1,
         get_url_port/1,
         s3_url/6,
         s3_url/7,
         put_object/5,
         put_object/6,
         set_object_acl/3,
         set_object_acl/4]).

-export([manual_start/0,
         make_authorization/10,
         universaltime/0]).

-ifdef(TEST).
-compile([export_all, nowarn_export_all]).
-include_lib("eunit/include/eunit.hrl").
-endif.

% is this used?  TODO: try removing
-include("internal.hrl").

-include_lib("xmerl/include/xmerl.hrl").

-include("erlcloud_aws.hrl").

-export_type([aws_config/0,
              bucket_attribute_name/0,
              bucket_acl/0,
              location_constraint/0]).

-type bucket_access_type() :: vhost | path.

-type bucket_attribute_name() :: acl
                               | location
                               | logging
                               | request_payment
                               | versioning.

-type settable_bucket_attribute_name() :: acl
                                        | logging
                                        | request_payment
                                        | versioning.

-type bucket_acl() :: private
                    | public_read
                    | public_read_write
                    | authenticated_read
                    | bucket_owner_read
                    | bucket_owner_full_control.

-type location_constraint() :: none
                             | us_west_1
                             | eu.

%% This is a helper function that exists to make development just a
%% wee bit easier
-spec manual_start() -> ok.
manual_start() ->
    application:start(crypto),
    application:start(public_key),
    application:start(ssl),
    application:start(inets).

-spec new(string() | binary(), string() | binary(), string()) -> aws_config().
new(AccessKeyID, SecretAccessKey, Host0) ->
    % chef-server crams scheme://host:port all into into Host; erlcloud wants them separate.
    % Assume:
    %   Host   == scheme://domain:port | scheme://domain | domain:port | domain
    %   scheme == http | https

    % ipv4/6 detection
    {Ipv, Host} =
        case string:tokens(Host0, "[]") of
            [Host0] ->
                % ipv4
                Domain0 = "",
                {4, Host0};
            % ipv6
            [Scheme0,    Domain0, Port0] -> {6, lists:flatten([Scheme0,    $x, Port0])};
            ["http://",  Domain0       ] -> {6, lists:flatten(["http://",  $x       ])};
            ["https://", Domain0       ] -> {6, lists:flatten(["https://", $x       ])};
            [            Domain0, Port0] -> {6, lists:flatten([            $x, Port0])};
            [            Domain0       ] -> {6, "x"}
        end,

    case string:split(Host, ":", all) of
        % Host == scheme://domain:port
        [Scheme1, [$/, $/ | Domain1] | [Port1]] ->
            Scheme = Scheme1 ++ "://";
        % Host == scheme://domain
        [Scheme1, [$/, $/ | Domain1]] ->
            Scheme = Scheme1 ++ "://",
            Port1  = undefined;
        % Host == domain:port
        [Domain1, Port1] ->
            Scheme = case Port1 of "80" -> "http://"; _ -> "https://" end;
        % Host == domain
        [Domain1] ->
            Scheme = "https://",
            Port1  = undefined
    end,
    Port =
        case Port1 of
            undefined ->
                case Scheme of
                    "https://" -> 443;
                    "http://"  -> 80
                end;
            _ ->
                list_to_integer(Port1)
        end,
    Domain = case Ipv of 4 -> Domain1; _ -> "[" ++ Domain0 ++ "]" end,
    %% bookshelf wants bucketname after host e.g. https://api.chef-server.dev:443/bookshelf...
    %% s3 wants bucketname before host (or it takes it either way) e.g. https://bookshelf.api.chef-server.dev:443...
    %% amazon: "Buckets created after September 30, 2020, will support only virtual hosted-style requests. Path-style
    %% requests will continue to be supported for buckets created on or before this date."
    %% for further discussion, see: https://github.com/chef/chef-server/issues/1911
    (erlcloud_s3:new(AccessKeyID, SecretAccessKey, Domain, Port))#aws_config{s3_scheme=Scheme, s3_bucket_after_host=true, s3_bucket_access_method=path}.

%-spec new(string(), string(), string(), bucket_access_type()) -> config().
-spec new(string() | binary(), string() | binary(), string(), bucket_access_type()) -> aws_config().

% erlcloud wants accesskey, secretaccesskey, host, port.
% mini_s3 wants accesskey, secretaccesskey, host, bucketaccesstype
new(AccessKeyID, SecretAccessKey, Host, BucketAccessType) ->
    % convert mini_s3 new/4 to erlcloud
    {BucketAccessMethod, BucketAfterHost} = case BucketAccessType of path -> {path, true}; _ -> {vhost, false} end,
    Config = new(AccessKeyID, SecretAccessKey, Host),
    Config#aws_config{
        s3_bucket_access_method=BucketAccessMethod,
        s3_bucket_after_host=BucketAfterHost
    }.

%-spec new(string(), string(), string(), bucket_access_type(), proplists:proplist()) -> config().
-spec new(string() | binary(), string() | binary(), string(), bucket_access_type(), proplists:proplist()) -> aws_config().

% erlcloud has no new/5. 
% also, arguments differ.  erlcloud's new/4 expects accesskeyid, secretaccesskey, host, port)
% erlcloud's signature is:
%   new(AccessKeyID::string(), SecretAccessKey::string(), Host::string(), Port::non_neg_integer()) -> aws_config()
% for now, attempting conversion to new/4
%
% this is called in oc_erchef in:
%   src/oc_erchef/apps/chef_objects/src/chef_s3.erl, line 168

new(AccessKeyID, SecretAccessKey, Host, BucketAccessType, _SslOpts) ->
    new(AccessKeyID, SecretAccessKey, Host, BucketAccessType).

-define(XMLNS_S3, "http://s3.amazonaws.com/doc/2006-03-01/").

-spec copy_object(string(), string(), string(), string(), proplists:proplist()) -> proplists:proplist().
copy_object(DestBucketName, DestKeyName, SrcBucketName, SrcKeyName, Options) ->
    erlcloud_s3:copy_object(DestBucketName, DestKeyName, SrcBucketName, SrcKeyName, Options).

copy_object(DestBucketName, DestKeyName, SrcBucketName, SrcKeyName, Options, Config) ->
    erlcloud_s3:copy_object(DestBucketName, DestKeyName, SrcBucketName, SrcKeyName, Options, Config).

%-spec create_bucket(string(), bucket_acl(), location_constraint()) -> ok.
create_bucket(BucketName, ACL, LocationConstraint) ->
    erlcloud_s3:create_bucket(BucketName, ACL, LocationConstraint).

%-spec create_bucket(string(), bucket_acl(), location_constraint(), config()) -> ok.
create_bucket(BucketName, ACL, LocationConstraint, Config) ->
    erlcloud_s3:create_bucket(BucketName, ACL, LocationConstraint, Config).

encode_acl(undefined)                 -> undefined;
encode_acl(private)                   -> "private";
encode_acl(public_read)               -> "public-read";
encode_acl(public_read_write)         -> "public-read-write";
encode_acl(authenticated_read)        -> "authenticated-read";
encode_acl(bucket_owner_read)         -> "bucket-owner-read";
encode_acl(bucket_owner_full_control) -> "bucket-owner-full-control".

% is this used?
%-spec delete_bucket(string()) -> ok.
delete_bucket(BucketName) ->
    erlcloud_s3:delete_bucket(BucketName).

%-spec delete_bucket(string(), config()) -> ok.
delete_bucket(BucketName, Config) ->
    erlcloud_s3:delete_bucket(BucketName, Config).

%-spec delete_object(string(), string()) -> proplists:proplist().
delete_object(BucketName, Key) ->
    erlcloud_s3:delete_object(BucketName, Key).

%-spec delete_object(string(), string(), config()) -> proplists:proplist().
delete_object(BucketName, Key, Config) ->
    erlcloud_s3:delete_object(BucketName, Key, Config).

%-spec delete_object_version(string(), string(), string()) ->
delete_object_version(BucketName, Key, Version) ->
    erlcloud_s3:delete_object_version(BucketName, Key, Version).

%-spec delete_object_version(string(), string(), string(), config()) ->
delete_object_version(BucketName, Key, Version, Config) ->
    erlcloud_s3:delete_object_version(BucketName, Key, Version, Config).

%-spec list_buckets(config()) -> proplists:proplist().
-spec list_buckets(aws_config()) -> proplists:proplist().

list_buckets(Config) ->
    Result = erlcloud_s3:list_buckets(Config),
    case proplists:lookup(buckets, Result) of none -> [{buckets, []}]; X -> [X] end.

%-spec list_objects(string(), proplists:proplist()) -> proplists:proplist().
list_objects(BucketName, Options) ->
    erlcloud_s3:list_objects(BucketName, Options).

%-spec list_objects(string(), proplists:proplist(), config()) -> proplists:proplist().
list_objects(BucketName, Options, Config) ->
    % wip attempt to fix ct tests
    List = erlcloud_s3:list_objects(BucketName, Options, Config),
    [{name, Name} | Rest] = List,
    [{name, http_uri:decode(Name)} | Rest].

extract_contents(Nodes) ->
    Attributes = [{key, "Key", text},
                  {last_modified, "LastModified", time},
                  {etag, "ETag", text},
                  {size, "Size", integer},
                  {storage_class, "StorageClass", text},
                  {owner, "Owner", fun extract_user/1}],
    [ms3_xml:decode(Attributes, Node) || Node <- Nodes].

extract_user([Node]) ->
    Attributes = [{id, "ID", text},
                  {display_name, "DisplayName", optional_text}],
    ms3_xml:decode(Attributes, Node).

%-spec get_bucket_attribute(string(), bucket_attribute_name()) -> term().
get_bucket_attribute(BucketName, AttributeName) ->
    erlcloud_s3:get_bucket_attribute(BucketName, AttributeName).

%-spec get_bucket_attribute(string(), bucket_attribute_name(), config()) -> term().
get_bucket_attribute(BucketName, AttributeName, Config) ->
    erlcloud_s3:get_bucket_attribute(BucketName, AttributeName, Config).

extract_acl(ACL) ->
    [extract_grant(Item) || Item <- ACL].

extract_grant(Node) ->
    [{grantee, extract_user(xmerl_xpath:string("Grantee", Node))},
     {permission, decode_permission(ms3_xml:get_text("Permission", Node))}].

encode_permission(full_control) -> "FULL_CONTROL";
encode_permission(write)        -> "WRITE";
encode_permission(write_acp)    -> "WRITE_ACP";
encode_permission(read)         -> "READ";
encode_permission(read_acp) -> "READ_ACP".

decode_permission("FULL_CONTROL") -> full_control;
decode_permission("WRITE")        -> write;
decode_permission("WRITE_ACP")    -> write_acp;
decode_permission("READ")         -> read;
decode_permission("READ_ACP")     -> read_acp.


%% @doc Canonicalizes a proplist of {"Header", "Value"} pairs by
%% lower-casing all the Headers.
-spec canonicalize_headers([{string() | binary() | atom(), Value::string()}]) ->
                                  [{LowerCaseHeader::string(), Value::string()}].
canonicalize_headers(Headers) ->
    [{string:to_lower(to_string(H)), V} || {H, V} <- Headers ].

-spec to_string(atom() | binary() | string()) -> string().
to_string(A) when is_atom(A) ->
    erlang:atom_to_list(A);
to_string(B) when is_binary(B) ->
    erlang:binary_to_list(B);
to_string(S) when is_list(S) ->
    S.

%% @doc Retrieves a value from a set of canonicalized headers.  The
%% given header should already be canonicalized (i.e., lower-cased).
%% Returns the value or the empty string if no such value was found.
-spec retrieve_header_value(Header::string(),
                            AllHeaders::[{Header::string(), Value::string()}]) ->
                                   string().
retrieve_header_value(Header, AllHeaders) ->
    proplists:get_value(Header, AllHeaders, "").

%% Abstraction of universaltime, so it can be mocked via meck
-spec universaltime() -> calendar:datetime().
universaltime() ->
    erlang:universaltime().

-spec if_not_empty(string(), iolist()) -> iolist().
if_not_empty("", _V) ->
    "";
if_not_empty(_, Value) ->
    Value.

-spec format_s3_uri(aws_config(), string()) -> string().
%format_s3_uri(#config{s3_url=S3Url, bucket_access_type=BAccessType}, Host) ->
format_s3_uri(Config, Host) ->
    % leaving off explicitly adding port for now, as this seems to be done automagically?
    %S3Url = Config#aws_config.s3_scheme ++ Config#aws_config.s3_host, % ++ ":" ++ integer_to_list(Config#aws_config.s3_port),
    S3Url = Config#aws_config.s3_host,
    Scheme0 = Config#aws_config.s3_scheme,
    % if scheme doesn't have ://, add it. if it does, leave it alone.
    Scheme = case string:split(Scheme0, "://", leading) of [Scheme0] -> Scheme0++"://"; [_, []] -> Scheme0 end,
    Port0 = integer_to_list(Config#aws_config.s3_port),
    BAccessType = Config#aws_config.s3_bucket_access_method,
    {ok,{Protocol,UserInfo,Domain,Port,_Uri,_QueryString}} =
        http_uri:parse(Scheme++S3Url++":"++Port0, [{ipv6_host_with_brackets, true}]),
    case BAccessType of
        vhost ->
            lists:flatten([erlang:atom_to_list(Protocol), "://",
                           if_not_empty(Host, [Host, $.]),
                           if_not_empty(UserInfo, [UserInfo, "@"]),
                           Domain, ":", erlang:integer_to_list(Port)]);
        path ->
            lists:flatten([erlang:atom_to_list(Protocol), "://",
                           if_not_empty(UserInfo, [UserInfo, "@"]),
                           Domain, ":", erlang:integer_to_list(Port),
                           if_not_empty(Host, [$/, Host])])
    end.

%% @doc Generate an S3 URL using Query String Request Authentication
%% (see
%% http://docs.amazonwebservices.com/AmazonS3/latest/dev/RESTAuthentication.html#RESTAuthenticationQueryStringAuth
%% for details).
%%
%% Note that this is **NOT** a complete implementation of the S3 Query
%% String Request Authentication signing protocol.  In particular, it
%% does nothing with "x-amz-*" headers, nothing for virtual hosted
%% buckets, and nothing for sub-resources.  It currently works for
%% relatively simple use cases (e.g., providing URLs to which
%% third-parties can upload specific files).
%%
%% Consult the official documentation (linked above) if you wish to
%% augment this function's capabilities.

-spec s3_url(atom(), string(), string(), integer() | {integer(), integer()},
             proplists:proplist(), aws_config()) -> binary().
s3_url(Method, BucketName0, Key0, {TTL, ExpireWin}, RawHeaders, Config) ->
    ?debugFmt("~nmini_s3:s3_url", []),
    {Date, Lifetime} = make_expire_win(TTL, ExpireWin),
    ?debugFmt("~nexpire window: ~p", [{Date, Lifetime}]),
    s3_url(Method, BucketName0, Key0, Lifetime, RawHeaders, Date, Config);
s3_url(Method, BucketName0, Key0, Lifetime, RawHeaders,
       Config = #aws_config{access_key_id=AccessKey,
                        secret_access_key=SecretKey})
  when is_list(BucketName0), is_list(Key0), is_tuple(Config) ->
    [BucketName, Key] = [ms3_http:url_encode_loose(X) || X <- [BucketName0, Key0]],
    RequestURI = erlcloud_s3:make_presigned_v4_url(Lifetime, BucketName, Method, Key, [], RawHeaders, Config),
    iolist_to_binary(RequestURI).

%-spec s3_url(atom(), string(), string(), integer() | {integer(), integer()},
-spec s3_url(atom(), string(), string(), integer(),
             proplists:proplist(), string(), aws_config()) -> binary().
s3_url(Method, BucketName0, Key0, Lifetime, RawHeaders, Date,
       Config = #aws_config{access_key_id=AccessKey,
                        secret_access_key=SecretKey})
  when is_list(BucketName0), is_list(Key0), is_tuple(Config) ->
    [BucketName, Key] = [ms3_http:url_encode_loose(X) || X <- [BucketName0, Key0]],
    RequestURI = erlcloud_s3:make_presigned_v4_url(Lifetime, BucketName, Method, Key, [], RawHeaders, Date, Config),

    iolist_to_binary(RequestURI).

%-----------------------------------------------------------------------------------
% implementation of expiration windows for sigv4
% for making batches of cacheable presigned URLs
%
%       PAST       PRESENT      FUTURE
%                     |
% -----+-----+-----+--+--+-----+-----+-----+--
%      |     |     |  |  |     |     |     |   TIME
% -----+-----+-----+--+--+-----+-----+-----+--
%                  |     |
%   x-amz-date ----+     +---- x-amz-expires
%
% 1) segment all of time into 'windows' of width expiry-window-size
% 2) align x-amz-date to nearest expiry-window boundary less than present time
% 3) align x-amz-expires to nearest expiry-window boundary greater than present time
%    while x-amz-expires - present < TTL, x-amz-expires += expiry-window-size
%-----------------------------------------------------------------------------------
-spec make_expire_win(non_neg_integer(), non_neg_integer()) -> {non_neg_integer(), non_neg_integer()}.
make_expire_win(TTL, ExpireWinSiz) ->
    UniversalTime = calendar:datetime_to_gregorian_seconds(calendar:now_to_universal_time(os:timestamp())),
    XAmzDateSec = UniversalTime div ExpireWinSiz * ExpireWinSiz,
    ExpirWinMult = ((TTL div ExpireWinSiz) + (case TTL rem ExpireWinSiz > 0 of true -> 1; _ -> 0 end)),
    XAmzExpires = case ExpirWinMult of 0 -> 1; _ -> ExpirWinMult end * ExpireWinSiz + XAmzDateSec,
    {erlcloud_aws:iso_8601_basic_time(calendar:gregorian_seconds_to_datetime(XAmzDateSec)), XAmzExpires}.

% not sure if this is used? doesn't use config.
%-spec get_object(string(), string(), proplists:proplist()) ->
%                        proplists:proplist().
get_object(BucketName, Key, Options) ->
    erlcloud_s3:get_object(BucketName, Key, Options).

%-spec get_object(string(), string(), proplists:proplist(), config()) ->
get_object(BucketName, Key, Options, Config) ->
    erlcloud_s3:get_object(BucketName, Key, Options, Config).

%-spec get_object_acl(string(), string()) -> proplists:proplist().
get_object_acl(BucketName, Key) ->
    erlcloud_s3:get_object_acl(BucketName, Key).

%-spec get_object_acl(string(), string(), proplists:proplist() | config()) -> proplists:proplist().
get_object_acl(BucketName, Key, Config) ->
    erlcloud_s3:get_object_acl(BucketName, Key, Config).

%-spec get_object_acl(string(), string(), proplists:proplist(), config()) -> proplists:proplist().
get_object_acl(BucketName, Key, Options, Config) ->
    erlcloud_s3:get_object_acl(BucketName, Key, Options, Config).

-spec get_object_metadata(string(), string(), proplists:proplist(), aws_config()) -> proplists:proplist().
get_object_metadata(BucketName, Key, Options, Config) ->
    erlcloud_s3:get_object_metadata(BucketName, Key, Options, Config).

extract_metadata(Headers) ->
    [{Key, Value} || {["x-amz-meta-"|Key], Value} <- Headers].

%-spec get_object_torrent(string(), string()) -> proplists:proplist().
get_object_torrent(BucketName, Key) ->
    erlcloud_s3:get_object_torrent(BucketName, Key).

%-spec get_object_torrent(string(), string(), config()) -> proplists:proplist().
get_object_torrent(BucketName, Key, Config) ->
    erlcloud_s3:get_object_torrent(BucketName, Key, Config).

%-spec list_object_versions(string(), proplists:proplist()) -> proplists:proplist().
list_object_versions(BucketName, Options) ->
    erlcloud_s3:list_object_versions(BucketName, Options).

% toggle port on host header (add port or remove it)
-spec get_host_toggleport(string(), aws_config()) -> string().
get_host_toggleport(Host, Config) ->
    case string:split(Host, ":", trailing) of
        [Host] ->
            Port = integer_to_list(Config#aws_config.s3_port),
            string:join([Host, Port], ":");
        ["http", _] ->
            Port = integer_to_list(Config#aws_config.s3_port),
            string:join([Host, Port], ":");
        ["https", _] ->
            Port = integer_to_list(Config#aws_config.s3_port),
            string:join([Host, Port], ":");
        [H, _] ->
            H
    end.

% construct url (scheme://host) from config
-spec get_url_noport(aws_config()) -> string().
get_url_noport(Config) ->
    UrlRaw  = get_url_port(Config),
    UrlTemp = string:trim(UrlRaw, trailing, "1234568790"),
    string:trim(UrlTemp, trailing, ":").

% construct url (scheme://host:port) from config
-spec get_url_port(aws_config()) -> string().
get_url_port(Config) ->
    Url0 = erlcloud_s3:get_object_url("", "", Config),
    Url1 = string:trim(Url0, trailing, "/"),
    case Config#aws_config.s3_port of
        80 ->
            % won't contain port if port == 80
            Url1 ++ ":80";
        _ ->
            Url1
    end.

list_object_versions(BucketName, Options, Config) ->
    erlcloud_s3:list_object_versions(BucketName, Options, Config).

extract_versions(Nodes) ->
    [extract_version(Node) || Node <- Nodes].

extract_version(Node) ->
    Attributes = [{key, "Key", text},
                  {version_id, "VersionId", text},
                  {is_latest, "IsLatest", boolean},
                  {etag, "ETag", text},
                  {size, "Size", integer},
                  {owner, "Owner", fun extract_user/1},
                  {storage_class, "StorageClass", text}],
    ms3_xml:decode(Attributes, Node).

extract_delete_markers(Nodes) ->
    [extract_delete_marker(Node) || Node <- Nodes].

extract_delete_marker(Node) ->
    Attributes = [{key, "Key", text},
                  {version_id, "VersionId", text},
                  {is_latest, "IsLatest", boolean},
                  {owner, "Owner", fun extract_user/1}],
    ms3_xml:decode(Attributes, Node).

extract_bucket(Node) ->
    ms3_xml:decode([{name, "Name", text},
                    {creation_date, "CreationDate", time}],
                   Node).

%-spec put_object(string(),
%                 string(),
%                 iolist(),
%                 proplists:proplist(),
%                 [{string(), string()}]) -> [{'version_id', _}, ...].
% is this used? (no Config)
put_object(BucketName, Key, Value, Options, HTTPHeaders) ->
    erlcloud_s3:put_object(BucketName, Key, Value, Options, HTTPHeaders).

%-spec put_object(string(),
%                 string(),
%                 iolist(),
%                 proplists:proplist(),
%                 [{string(), string()}],
%                 config()) -> [{'version_id', _}, ...].
put_object(BucketName, Key, Value, Options, HTTPHeaders, Config) ->
    erlcloud_s3:put_object(BucketName, Key, Value, Options, HTTPHeaders, Config).

%-spec set_object_acl(string(), string(), proplists:proplist()) -> ok.
set_object_acl(BucketName, Key, ACL) ->
    erlcloud_s3:set_object_acl(BucketName, Key, ACL).

%-spec set_object_acl(string(), string(), proplists:proplist(), config()) -> ok.
set_object_acl(BucketName, Key, ACL, Config) ->
    erlcloud_s3:set_object_acl(BucketName, Key, ACL, Config).

%-spec set_bucket_attribute(string(),
%                           settable_bucket_attribute_name(),
%                           'bucket_owner' | 'requester' | [any()]) -> ok.
set_bucket_attribute(BucketName, AttributeName, Value) ->
    erlcloud_s3:set_bucket_attribute(BucketName, AttributeName, Value).

%-spec set_bucket_attribute(string(), settable_bucket_attribute_name(),
%                           'bucket_owner' | 'requester' | [any()], config()) -> ok.
set_bucket_attribute(BucketName, AttributeName, Value, Config) ->
    erlcloud_s3:set_bucket_attribute(BucketName, AttributeName, Value, Config).

encode_grants(Grants) ->
    [encode_grant(Grant) || Grant <- Grants].

encode_grant(Grant) ->
    Grantee = proplists:get_value(grantee, Grant),
    {'Grant',
     [{'Grantee', [{xmlns, ?XMLNS_S3}],
       [{'ID', [proplists:get_value(id, proplists:get_value(owner, Grantee))]},
        {'DisplayName', [proplists:get_value(display_name, proplists:get_value(owner, Grantee))]}]},
      {'Permission', [encode_permission(proplists:get_value(permission, Grant))]}]}.

s3_simple_request(Config, Method, Host, Path, Subresource, Params, POSTData, Headers) ->
    case s3_request(Config, Method, Host, Path,
                    Subresource, Params, POSTData, Headers) of
        {_Headers, ""} -> ok;
        {_Headers, Body} ->
            XML = element(1,xmerl_scan:string(Body)),
            case XML of
                #xmlElement{name='Error'} ->
                    ErrCode = ms3_xml:get_text("/Error/Code", XML),
                    ErrMsg = ms3_xml:get_text("/Error/Message", XML),
                    erlang:error({s3_error, ErrCode, ErrMsg});
                _ ->
                    ok
            end
    end.

s3_xml_request(Config, Method, Host, Path, Subresource, Params, POSTData, Headers) ->
    {_Headers, Body} = s3_request(Config, Method, Host, Path,
                                  Subresource, Params, POSTData, Headers),
    XML = element(1,xmerl_scan:string(Body)),
    case XML of
        #xmlElement{name='Error'} ->
            ErrCode = ms3_xml:get_text("/Error/Code", XML),
            ErrMsg = ms3_xml:get_text("/Error/Message", XML),
            erlang:error({s3_error, ErrCode, ErrMsg});
        _ ->
            XML
    end.

s3_request(Config = #config{access_key_id=AccessKey,
                            secret_access_key=SecretKey,
                            ssl_options=SslOpts},
           Method, Host, Path, Subresource, Params, POSTData, Headers) ->
    {ContentMD5, ContentType, Body} =
        case POSTData of
            {PD, CT} ->
                {base64:encode(erlang:md5(PD)), CT, PD};
            PD ->
                %% On a put/post even with an empty body we need to
                %% default to some content-type
                case Method of
                    _ when put == Method; post == Method ->
                        {"", "text/xml", PD};
                    _ ->
                        {"", "", PD}
                end
        end,
    AmzHeaders = lists:filter(fun ({"x-amz-" ++ _, V}) when
                                        V =/= undefined -> true;
                                  (_) -> false
                              end, Headers),
    Date = httpd_util:rfc1123_date(erlang:localtime()),
    EscapedPath = ms3_http:url_encode_loose(Path),
    FHeaders = [Header || {_, Value} = Header <- Headers, Value =/= undefined],
    RequestHeaders0 = FHeaders ++
        case ContentMD5 of
            "" -> [];
            _ -> [{"content-md5", binary_to_list(ContentMD5)}]
        end,
    RequestHeaders1 = case proplists:is_defined("Content-Type", RequestHeaders0) of
                          true ->
                              RequestHeaders0;
                          false ->
                              [{"Content-Type", ContentType} | RequestHeaders0]
                      end,
    IbrowseOpts = [ {ssl_options, SslOpts} ],
    [$/ | Key] = Path,
    Lifetime = 900,
    RequestURI = s3_url(Method, Host, Key, Lifetime, RequestHeaders1, Date, Config),
    Response = case Method of
                   get ->
                       ibrowse:send_req(RequestURI, RequestHeaders1, Method, [], IbrowseOpts);
                   delete ->
                       ibrowse:send_req(RequestURI, RequestHeaders1, Method, [], IbrowseOpts);
                   head ->
                       %% ibrowse is unable to handle HEAD request responses that are sent
                       %% with chunked transfer-encoding (why servers do this is not
                       %% clear). While we await a fix in ibrowse, forcing the HEAD request
                       %% to use HTTP 1.0 works around the problem.
                       IbrowseOpts1 = [{http_vsn, {1, 0}} | IbrowseOpts],
                       ibrowse:send_req(RequestURI, RequestHeaders1, Method, [],
                                        IbrowseOpts1);
                   _ ->
                       ibrowse:send_req(RequestURI, RequestHeaders1, Method, Body, IbrowseOpts)
               end,
    case Response of
        {ok, Status, ResponseHeaders0, ResponseBody} ->
            ResponseHeaders = canonicalize_headers(ResponseHeaders0),
            case erlang:list_to_integer(Status) of
                OKStatus when OKStatus >= 200, OKStatus =< 299 ->
                    {ResponseHeaders, ResponseBody};
                BadStatus ->
                    erlang:error({aws_error, {http_error, BadStatus,
                                              {ResponseHeaders, ResponseBody}}})
                end;
        {error, Error} ->
            erlang:error({aws_error, {socket_error, Error}})
    end.

make_authorization(AccessKeyId, SecretKey, Method, ContentMD5, ContentType, Date, AmzHeaders,
                   Host, Resource, Subresource) ->
    CanonizedAmzHeaders =
        [[Name, $:, Value, $\n] || {Name, Value} <- lists:sort(AmzHeaders)],
    StringToSign = [string:to_upper(atom_to_list(Method)), $\n,
                    ContentMD5, $\n,
                    ContentType, $\n,
                    Date, $\n,
                    CanonizedAmzHeaders,
                    if_not_empty(Host, [$/, Host]),
                    Resource,
                    if_not_empty(Subresource, [$?, Subresource])],
    Signature = base64:encode(crypto:hmac(sha, SecretKey, StringToSign)),
    {StringToSign, ["AWS ", AccessKeyId, $:, Signature]}.

default_config() ->
    Defaults =  envy:get(mini_s3, s3_defaults, list),
    case proplists:is_defined(key_id, Defaults) andalso
        proplists:is_defined(secret_access_key, Defaults) of
        true ->
            {key_id, Key} = proplists:lookup(key_id, Defaults),
            {secret_access_key, AccessKey} =
                proplists:lookup(secret_access_key, Defaults),
            #aws_config{access_key_id=Key, secret_access_key=AccessKey};
        false ->
            throw({error, missing_s3_defaults})
    end.
