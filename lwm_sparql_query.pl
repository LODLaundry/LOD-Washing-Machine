:- module(
  lwm_sparql_query,
  [
    lwm_sparql_ask/3, % +Prefixes:list(atom)
                      % +Bgps:list(compound)
                      % +Options:list(nvpair)
    lwm_sparql_select/5, % +Prefixes:list(atom)
                         % +Variables:list(atom)
                         % +Bgps:list(compound)
                         % -Result:list(list)
                         % +Options:list(nvpair)
    lwm_sparql_select_iteratively/5, % +Prefixes:list(atom)
                                     % +Variables:list(atom)
                                     % +Bgps:list(compound)
                                     % -Result:list(list)
                                     % +Options:list(nvpair)
    datadoc_archive_entry/3, % +Datadoc:uri
                             % -ParentMd5:atom
                             % -EntryPath:atom
    datadoc_cleaning/1, % -Datadoc:uri
    datadoc_content_type/2, % +Datadoc:uri
                            % -ContentType:atom
    datadoc_describe/2, % +Md5:atom
                        % -Triples:list(compound)
    datadoc_file_extension/2, % +Datadoc:uri
                              % -FileExtension:atom
    datadoc_pending/2, % -Datadoc:uri
                       % -Dirty:uri
    datadoc_source/2, % +Datadoc:uri
                      % -Source:atom
    datadoc_unpacked/4, % ?Min:nonneg
                        % ?Max:nonneg
                        % -Datadoc:uri
                        % -Size:nonneg
    datadoc_unpacking/1 % -Datadoc:uri
  ]
).

/** <module> LOD Washing Machine (LWM): SPARQL queries

SPARQL queries for the LOD Washing Machine.

@author Wouter Beek
@version 2014/06, 2014/08-2014/09, 2014/11, 2015/01
*/

:- use_module(library(apply)).
:- use_module(library(lists), except([delete/3,subset/2])).
:- use_module(library(option)).

:- use_module(generics(meta_ext)).

:- use_module(plRdf(term/rdf_literal)).

:- use_module(plSparql(query/sparql_query_api)).

:- use_module(lwm(lwm_settings)).





% GENERICS %

lwm_sparql_ask(Prefixes, Bgps, Options1):-
  lwm_version_graph(Graph),
  merge_options([named_graph(Graph),sparql_errors(fail)], Options1, Options2),
  (   lwm:lwm_server(virtuoso)
  ->  Endpoint = virtuoso_query
  ;   lwm:lwm_server(cliopatria)
  ->  Endpoint = cliopatria_localhost
  ),
  loop_until_true(
    sparql_ask(Endpoint, Prefixes, Bgps, Options2)
  ).


lwm_sparql_select(Prefixes, Variables, Bgps, Result, Options1):-
  get_endpoint(Endpoint),
  sparql_select_options(Options1, Options2),
  loop_until_true(
    sparql_select(Endpoint, Prefixes, Variables, Bgps, Result, Options2)
  ).


lwm_sparql_select_iteratively(Prefixes, Variables, Bgps, Result, Options1):-
  get_endpoint(Endpoint),
  sparql_select_options(Options1, Options2),
  loop_until_true(
    sparql_select_iteratively(
      Endpoint,
      Prefixes,
      Variables,
      Bgps,
      Result,
      Options2
    )
  ).





% QUERIES %

%! datadoc_archive_entry(+Datadoc:uri, -ParentMd5:atom, -EntryPath:atom) is det.

datadoc_archive_entry(Datadoc, ParentMd5, EntryPath):-
  lwm_sparql_select(
    [llo],
    [parentMd5,entryPath],
    [
      rdf(Datadoc, llo:path, var(entryPath)),
      rdf(var(md5parent), llo:containsEntry, Datadoc),
      rdf(var(md5parent), llo:md5, var(parentMd5))
    ],
    [Row],
    [limit(1)]
  ),
  maplist(rdf_literal_data(value), Row, [ParentMd5,EntryPath]).


%! datadoc_cleaning(-Datadoc:uri) is nondet.

datadoc_cleaning(Datadoc):-
  lwm_sparql_select(
    [llo],
    [datadoc],
    [
      rdf(var(datadoc), llo:startClean, var(startClean)),
      not([
        rdf(var(datadoc), llo:endClean, var(endClean))
      ])
    ],
    Rows,
    []
  ),
  member([Datadoc], Rows).


%! datadoc_content_type(+Datadoc:uri, -ContentType:atom) is semidet.
% Returns a variable if the content type is not known.

datadoc_content_type(Datadoc, ContentType):-
  lwm_sparql_select(
    [llo],
    [contentType],
    [rdf(Datadoc, llo:contentType, var(contentType))],
    [[ContentTypeLiteral]],
    [limit(1)]
  ),
  rdf_literal_data(value, ContentTypeLiteral, ContentType).


%! datadoc_describe(+Datadoc:uri, -Triples:list(compound)) is det.

datadoc_describe(Datadoc, Triples):-
  lwm_sparql_select(
    [llo],
    [p,o],
    [rdf(Datadoc, var(p), var(o))],
    Rows,
    [distinct(true)]
  ),
  maplist(pair_to_triple(Datadoc), Rows, Triples).


%! datadoc_file_extension(+Datadoc:uri, -FileExtension:atom) is det.

datadoc_file_extension(Datadoc, FileExtension):-
  lwm_sparql_select(
    [llo],
    [fileExtension],
    [rdf(Datadoc, llo:fileExtension, var(fileExtension))],
    [[FileExtensionLiteral]],
    [limit(1)]
  ),
  rdf_literal_data(value, FileExtensionLiteral, FileExtension).


%! datadoc_pending(-Datadoc:uri, -Dirty:uri) is nondet.
% @tbd Make sure that at no time two data documents are
%      being downloaded from the same host.
%      This avoids being blocked by servers that do not allow
%      multiple simultaneous requests.
%      ~~~{.pl}
%      (   nonvar(DirtyUrl)
%      ->  uri_component(DirtyUrl, host, Host),
%          \+ lwm:current_host(Host),
%          % Set a lock on this host for other unpacking threads.
%          assertz(lwm:current_host(Host))
%      ;   true
%      ), !,
%      ~~~
%      Add argument `Host` for releasing the lock in [lwm_unpack].

datadoc_pending(Datadoc, Dirty):-
  lwm_sparql_select(
    [llo],
    [datadoc,dirty],
    [
      rdf(var(datadoc), llo:added, var(added)),
      not([
        rdf(var(datadoc), llo:startUnpack, var(startUnpack))
      ]),
      optional([
        rdf(var(datadoc), llo:url, var(dirty))
      ])
    ],
    [[Datadoc,Dirty]],
    [limit(1)]
  ).


%! datadoc_source(+Datadoc:uri, -Source:atom) is det.
% Returns the original source of the given datadocument.
%
% This is either a URL simpliciter,
% or a URL suffixed by an archive entry path.

% The data document derives from a URL.
datadoc_source(Datadoc, Url):-
  lwm_sparql_select(
    [llo],
    [url],
    [rdf(Datadoc, llo:url, var(url))],
    [[Url]],
    [limit(1)]
  ), !.
% The data document derives from an archive entry.
datadoc_source(Datadoc, Source):-
  lwm_sparql_select(
    [llo],
    [parent,path],
    [
      rdf(Datadoc, llo:path, var(path)),
      rdf(var(parent), llo:containsEntry, Datadoc)
    ],
    [[Parent,PathLiteral]],
    [limit(1)]
  ),
  rdf_literal_data(value, PathLiteral, Path),
  datadoc_source(Parent, ParentSource),
  atomic_concat(ParentSource, Path, Source).


%! datadoc_unpacked(
%!   ?Min:nonneg,
%!   ?Max:nonneg,
%!   -Datadoc:uri,
%!   -UnpackedSize:nonneg
%! ) is semidet.
% UnpackedSize is expressed as the number of bytes.

datadoc_unpacked(Min, Max, Datadoc, UnpackedSize):-
  build_unpacked_query(Min, Max, Query),
  lwm_sparql_select(
    [llo],
    [datadoc,unpackedSize],
    Query,
    [[Datadoc,UnpackedSizeLiteral]],
    [limit(1)]
  ),
  rdf_literal_data(value, UnpackedSizeLiteral, UnpackedSize).
conjunctive_filter([H], H):- !.
conjunctive_filter([H|T1], and(H,T2)):-
  conjunctive_filter(T1, T2).


%! datadoc_unpacking(-Datadoc:uri) is nondet.

datadoc_unpacking(Datadoc):-
  lwm_sparql_select(
    [llo],
    [datadoc],
    [
      rdf(var(datadoc), llo:startUnpack, var(startUnpack)),
      not([
        rdf(var(datadoc), llo:endUnpack, var(endUnpack))
      ])
    ],
    Rows,
    []
  ),
  member([Datadoc], Rows).





% HELPERS %

%! build_unpacked_query(?Min:nonneg, ?Max:nonneg, -Query:atom) is det.

build_unpacked_query(Min, Max, Query2):-
  Query1 = [
    rdf(var(datadoc), llo:endUnpack, var(endUnpack)),
    not([
      rdf(var(datadoc), llo:startClean, var(startClean))
    ]),
    rdf(var(datadoc), llo:unpackedSize, var(unpackedSize))
  ],

  % Insert the range restriction on the unpacked file size as a filter.
  (   nonvar(Min)
  ->  MinFilter = >(var(unpackedSize),Min)
  ;   true
  ),
  (   nonvar(Max)
  ->  MaxFilter = <(var(unpackedSize),Max)
  ;   true
  ),
  exclude(var, [MinFilter,MaxFilter], FilterComponents),
  (   conjunctive_filter(FilterComponents, FilterContent)
  ->  append(Query1, [filter(FilterContent)], Query2)
  ;   Query2 = Query1
  ).


%! get_endpoint(-Endpoint:atom) is det.

get_endpoint(Endpoint):-
  lwm:lwm_server(virtuoso), !,
  Endpoint = virtuoso_query.
get_endpoint(Endpoint):-
  lwm:lwm_server(cliopatria), !,
  Endpoint = cliopatria_localhost.


pair_to_triple(S, [P,O], rdf(S,P,O)).


%! sparql_select_options(
%!   +Options1:list(nvpair),
%!   -Options2:list(nvpair)
%! ) is det.

sparql_select_options(Options1, Options2):-
  % Set the RDF Dataset over which SPARQL Queries are executed.
  lod_basket_graph(BasketGraph),
  lwm_version_graph(LwmGraph),
  merge_options(
    [default_graph(BasketGraph),default_graph(LwmGraph),sparql_errors(fail)],
    Options1,
    Options2
  ).
