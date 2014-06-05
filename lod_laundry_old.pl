:- module(
  lod_laundry,
  [
    non_url_iris/5 % -NonUrlIris:ordset(iri)
                   % -NumberOfNonUrlIris:nonneg
                   % -UrlIris:orset(url)
                   % -NumberOfNonUrlIris:nonneg
                   % -PercentageOfNonUrlIris:between(0.0,1.0)
  ]
).

/** <module> LOD laundry

@author Wouter Beek
@version 2014/05
*/

:- use_module(library(aggregate)).
:- use_module(library(http/html_write)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(pairs)).
:- use_module(library(semweb/rdf_db)).
:- use_module(library(semweb/rdfs)).
:- use_module(library(url)).

:- use_module(generics(db_ext)).
:- use_module(math(math_ext)).
:- use_module(os(datetime_ext)).
:- use_module(xml(xml_namespace)).

:- use_module(plHtml(html)).
:- use_module(plHtml(html_pl_term)).
:- use_module(plHtml(html_table)).

:- use_module(plServer(web_modules)). % Web module registration.

:- use_module(plRdf_ser(rdf_file_db)).
:- use_module(plRdf_ser(rdf_serial)).
:- use_module(plRdf_term(rdf_datatype)).
:- use_module(plRdf_term(rdf_string)).

:- use_module(plTabular(rdf_tabular)). % Debug tool.

:- use_module(lwm(reply_json)).

:- xml_register_namespace(ap, 'http://www.wouterbeek.com/ap.owl#').
:- xml_register_namespace(ckan, 'http://www.wouterbeek.com/ckan#').

http:location(ll_web, root(ll), []).
:- http_handler(ll_web(.), ll_web_home, [prefix]).

user:web_module('LOD Laundry', ll_web_home).

%! rdf_triple(
%!   ?Subject:or([bnode,iri]),
%!   ?Predicate:iri,
%!   ?Object:or([bnode,iri,literal])
%! ) is nondet.
% Used to load triples from the messages logging file.

:- dynamic(rdf_triple/3).

:- dynamic(url_md5_translation/2).

:- multifile(prolog:message//1).

:- discontiguous(lod_url_property/3).

:- db_add_novel(user:prolog_file_type(log, logging)).

:- initialization(init_ll).


%! init_ll is det.
% Loads the triples from the messages log and the datahub scrape.

init_ll:-
  %init_datahub,
  init_messages,
  cache_url_md5_translations.

init_datahub:-
  rdf_graph(datahub), !.
init_datahub:-
  absolute_file_name(
    data('http/datahub.io/catalog'),
    File,
    [access(read),file_type(turtle)]
  ),
  rdf_load_any([graph(datahub)], File).

init_messages:-
  rdf_graph(messages), !.
init_messages:-
  absolute_file_name(
    data(messages),
    File,
    [access(read),file_errors(fail),file_type(ntriples)]
  ),
  rdf_load_any([graph(messages)], File), !.
init_messages:-
  absolute_file_name(
    data(messages),
    FromFile,
    [access(read),file_type(logging)]
  ),
  setup_call_cleanup(
    ensure_loaded(FromFile),
    forall(
      rdf_triple(S, P, O),
      rdf_assert(S, P, O, messages)
    ),
    unload_file(FromFile)
  ),
  absolute_file_name(data(messages), ToFile, [access(write),file_type(ntriples)]),
  rdf_save([format(ntriples)], messages, ToFile).

cache_url_md5_translation(Url):-
  rdf_atom_md5(Url, 1, Md5),
  assert(url_md5_translation(Url, Md5)).

cache_url_md5_translations:-
  lod_url(Url),
  cache_url_md5_translation(Url),
  fail.
cache_url_md5_translations.


% Response to requesting a JSON description of all LOD URL.
ll_web_home(Request):-
  memberchk(path_info('all.json'), Request), !,
  aggregate_all(
    set(Url=Dict),
    (
      lod_url(Url),
      Url \== 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
      lod_url_dict(Url, Dict),
      print_message(informational, tick)
    ),
    NVPairs
  ),
  dict_create(Results, results, NVPairs),
  iso8601_dateTime(Now),
  dict_create(Dict, all, [lastModifiedJson=Now,results=Results,scrapeAttempt=5]),
  reply_json_dict(Dict, [cache(3600),cors(true)]).
% Response to requesting a JSON description of a single LOD URL.
ll_web_home(Request):-
  memberchk(path_info(Path), Request),
  file_name_extension(Md5, json, Path),
  url_md5_translation(Url, Md5), !,
  lod_url_dict(Url, Dict),
  reply_json_dict(Dict, [cache(3600),cors(true)]).
% Generic response.
ll_web_home(_Request):-
  reply_html_page(
    app_style,
    title('LOD Laundry'),
    html([
      h1('LOD Laundry'),
      \lod_urls
    ])
  ).
% DEB
prolog:message(tick) -->
  {flag(flag_log, X, X + 1)},
  [X].


%! lod_url(?Url:url) is nondet.
% Enumerates the LOD URLs that have been washed.

lod_url(Url):-
  rdfs_individual_of(Url, ap:'LOD-URL').


%! lod_url_dict(+Url:url, -Dict:dict) is det.

lod_url_dict(Url, Dict):-
  findall(
    Name=Value,
    lod_url_property(Url, Name, Value),
    NVPairs
  ),
  dict_create(Dict, Url, NVPairs).


%! lod_urls// is det.
% Enumerates the washed LOD URLs.

lod_urls -->
  {
    aggregate_all(
      set([Url-InternalLink-Url]),
      (
        lod_url(Url),
        once(url_md5_translation(Url, Md5)),
        once(file_name_extension(Md5, json, File)),
        once(http_link_to_id(ll_web_home, path_postfix(File), InternalLink))
      ),
      Rows
    )
  },
  html_table(
    [header_column(true),header_row(true),indexed(true)],
    html('LOD files'),
    lod_laundry_cell,
    [['Url']|Rows]
  ).


%! lod_url_property(+Url:url, +Name:atom, -Value) is det.

%Archive.
lod_url_property(Url, archiveEntry_size, Size):-
  once(rdf_datatype(Url, ap:size, Size, xsd:integer, messages)).
lod_url_property(Url, fromArchive, Archive):-
  once(rdf(Archive, ap:archive_contains, Url)).
lod_url_property(Url1, hasArchiveEntry, Urls):-
  findall(
    Url2,
    rdf(Url1, ap:archive_contains, Url2),
    Urls
  ),
  Urls \== [].

% Base IRI.
lod_url_property(Url, baseIri, Base):-
  rdf(Url, ap:base_iri, Base).

% RDF.
lod_url_property(Url, rdf, Dict):-
  findall(
    N-V,
    rdf_property(Url, N, V),
    Pairs
  ),
  Pairs \== [],
  dict_pairs(Dict, rdf, Pairs).

rdf_property(Url, duplicates, Duplicates):-
  once(rdf_datatype(Url, ap:duplicates, Duplicates, xsd:integer, messages)).
rdf_property(Url, triples, Triples):-
  once(rdf_datatype(Url, ap:triples, Triples, xsd:integer, messages)).
rdf_property(Url, serializationFormat, Format):-
  once(rdf_string(Url, ap:serialization_format, Format, messages)).
% Syntax errors
rdf_property(Url, syntaxErrors, Errors):-
  aggregate_all(
    set(Error2),
    (
      rdf_string(Url, ap:message, Error1, messages),
      atom_to_term(Error1, message(Term,_,Lines), _),
      \+ Term = error(_,_),
      with_output_to(
        atom(Error2),
        print_message_lines(current_output, '', Lines)
      )
    ),
    Errors
  ),
  Errors \== [].


% HTTP response.
lod_url_property(Url, httpResponse, Dict):-
  findall(
    Name-Value,
    http_response_property(Url, Name, Value),
    Pairs
  ),
  Pairs \== [],
  dict_pairs(Dict, http_response, Pairs).

% File.
lod_url_property(Url, fileExtension, FileExtension):-
  once(rdf_string(Url, ap:file_extension, FileExtension, messages)).

% MD5
lod_url_property(Url, md5, Md5):-
  once(url_md5_translation(Url, Md5)).

% Exceptions
lod_url_property(Url, exceptions, Dict):-
  findall(
    Kind-Exceptions,
    kind_exceptions(Url, Kind, Exceptions),
    Pairs1
  ),
  Pairs1 \== [],
  group_pairs_by_key(Pairs1, Pairs2),
  dict_pairs(Dict, exceptions, Pairs2).

kind_exceptions(Url, Kind, Exception):-
  once(rdf_string(Url, ap:exception, Atom, messages)),
  atom_to_term(Atom, Term, _),
  kind_exception(Term, Kind, Exception).

kind_exception(error(socket_error(Msg),_), tcp, Msg).
kind_exception(error(existence_error(url,_),context(_,status(Status,_))), http, Status).
kind_exception(error(permission_error(url,_),context(_,status(Status,_))), http, Status).
kind_exception(error(type_error(xml_dom,DOM),_), syntax, Atom):-
  term_to_atom(DOM, Atom).

% Status?
lod_url_property(Url, status, Status):-
  once(rdf_string(Url, ap:status, Status, messages)).

% Stream?
lod_url_property(Url, stream, Dict):-
  findall(
    N-V,
    stream_property(Url, N, V),
    Pairs
  ),
  Pairs \== [],
  dict_pairs(Dict, stream, Pairs).

stream_property(Url, byteCount, ByteCount):-
  once(rdf_datatype(Url, ap:stream_byte_count, ByteCount, xsd:integer, messages)).
stream_property(Url, charCount, CharCount):-
  once(rdf_datatype(Url, ap:stream_char_count, CharCount, xsd:integer, messages)).
stream_property(Url, lineCount, LineCount):-
  once(rdf_datatype(Url, ap:stream_line_count, LineCount, xsd:integer, messages)).

% URL
lod_url_property(Url, url, Url).

http_response_property(Url, contentLength, ContentLength):-
  once(rdf_datatype(Url, ap:http_content_length, ContentLength, xsd:integer, messages)).
http_response_property(Url, contentType, ContentType):-
  once(rdf_string(Url, ap:http_content_type, ContentType, messages)).
http_response_property(Url, lastModified, LastModified):-
  once(rdf_string(Url, ap:http_last_modified, LastModified, messages)).


%! ckan_resources// is det.

ckan_resources -->
  {
    findall(
      Name-Row,
      (
        rdfs_individual_of(CkanResource, ckan:'Resource'),
        rdf_string(CkanResource, ckan:name, Name, datahub),
        rdf_string(CkanResource, ckan:url, Url, datahub),
        Row = [Url-Name]
      ),
      Pairs1
    ),
    keysort(Pairs1, Pairs2),
    pairs_values(Pairs2, Rows)
  },
  html_table(
    [header_column(true),header_row(true),indexed(true)],
    html('CKAN resources'),
    lod_laundry_cell,
    [['Name']|Rows]
  ).

lod_laundry_cell(Term) -->
  {
    nonvar(Term),
    Term = Name-InternalLink-ExternalLink
  }, !,
  html([
    \html_link(InternalLink-Name),
    ' ',
    \html_external_link(ExternalLink)
  ]).
lod_laundry_cell(Term) -->
  html_pl_term(plDev(.), Term).



% STATISTICS %

%! non_url_iris(
%!   -NonUrlIris:ordset(iri),
%!   -NumberOfNonUrlIris:nonneg,
%!   -UrlIris:orset(url),
%!   -NumberOfNonUrlIris:nonneg,
%!   -PercentageOfNonUrlIris:between(0.0,1.0)
%! ) is det.

non_url_iris(NonUrlIris, NumberOfNonUrlIris, UrlIris, NumberOfUrlIris, Perc):-
  aggregate_all(
    set(NonUrlIri),
    (
      lod_url(NonUrlIri),
      url_iri(Url, NonUrlIri),
      Url \== NonUrlIri
    ),
    NonUrlIris
  ),
  length(NonUrlIris, NumberOfNonUrlIris),

  aggregate_all(
    set(UrlIri),
    (
      lod_url(UrlIri),
      url_iri(Url, UrlIri),
      Url == UrlIri
    ),
    UrlIris
  ),
  length(UrlIris, NumberOfUrlIris),

  percentage(NumberOfNonUrlIris, NumberOfUrlIris, Perc).

percentage(X, Y, Perc):-
  div_zero(X, Y, Perc).


number_of_urls(N):-
  aggregate_all(
    count,
    lod_url(_),
    N
  ).


%! http_status_codes(
%!   -Triples:triple(between(200,599),nonneg,between(0.0,1.0))
%! ) is det.

http_status_codes(Triples):-
  aggregate_all(
    set(Status-Url),
    (
      rdf_string(Url, ap:status, S, messages),
      atom_to_term(S, T, _),
      T = error(_,context(_,status(Status,_)))
    ),
    Pairs1
  ),
  group_pairs_by_key(Pairs1, Pairs2),
  pairs_keys_values(Pairs2, Keys, Values),
  maplist(length, Values, ValuesSize),
  pairs_keys_values(Pairs3, Keys, ValuesSize),
  number_of_urls(N),
  maplist(pair_to_triple(N), Pairs3, Triples).

pair_to_triple(N, X-Y, X-Y-Z):-
  percentage(Y, N, Z).
