:- module(
  ll_show,
  [
    export_uri/1, % ?Uri
    show_uri/1    % ?Uri
  ]
).

/** <module> LOD Laundromat: Show

@author Wouter Beek
@version 2017/09-2017/11
*/

:- use_module(library(aggregate)).
:- use_module(library(apply)).
:- use_module(library(atom_ext)).
:- use_module(library(date_time)).
:- use_module(library(dcg/dcg_ext)).
:- use_module(library(debug_ext)).
:- use_module(library(dict_ext)).
:- use_module(library(graph/gv)).
:- use_module(library(http/http_generic)).
:- use_module(library(lists)).
:- use_module(library(stream_ext)).
:- use_module(library(uri/uri_ext)).
:- use_module(library(yall)).

:- use_module(ll_generics).
:- use_module(ll_seedlist).

:- debug(dot).





%! export_uri(?Uri:atom) is det.
%
% Exports the LOD Laundromat job for the given URI to a PDF file, or
% to a file in some other Format.

export_uri(Uri) :-
  (var(Uri) -> seed(Seed), _{uri: Uri} :< Seed ; true),
  uri_hash(Uri, Hash),
  Format = pdf,%SETTING
  file_name_extension(Hash, Format, File),
  gv_export(dot, Format, File, {Hash}/[Out]>>seed2dot(Out, Hash)).



%! show_uri(?Uri:atom) is det.
%
% Shows the LOD Laundromat job for the given URI in X11, or in some
% other Program.

show_uri(Uri) :-
  (var(Uri) -> seed(Seed), _{uri: Uri} :< Seed ; true),
  print_message(informational, show_uri(Uri)),
  Program = gtk,%SETTING
  uri_hash(Uri, Hash),
  gv_show(dot, Program, {Hash}/[Out]>>seed2dot(Out, Hash)).





% GENERICS %

seed2dot(Out, Hash) :-
  format_debug(dot, Out, "digraph g {"),
  seed2gv_hash(Out, Hash),
  format_debug(dot, Out, "}").

seed2gv_hash(Out, Hash) :-
  seed(Hash, Dict),
  seed2gv_dict(Out, Dict).

% error
seed2gv_dict(Out, Dict) :-
  Hash{
    error: Error,
    status: Status
  } :< Dict, !,
  format(string(Header), "<B>~a</B>", [Status]),
  error_label(Error, ErrorLabel),
  atomic_concat(n, Hash, Id),
  hash_label(Hash, HashLabel),
  gv_node(Out, Id, [label([Header,HashLabel,ErrorLabel]),shape(box)]).
% URI
seed2gv_dict(Out, Dict) :-
  Hash1{
    added: _Added,
    interval: Interval,
    processed: Processed,
    uri: Uri
  } :< Dict, !,
  dict_get(children, Dict, [], Hash2s),
  maplist(atomic_concat(n), [Hash1|Hash2s], [Id1|Id2s]),
  format(string(Header), "<B>URI: ~a</B>", [Uri]),
  maplist(
    property_label,
    [interval(Interval),processed(Processed)],
    Labels
  ),
  hash_label(Hash1, Hash1Label),
  gv_node(Out, Id1, [label([Header,Hash1Label|Labels]),shape(box)]),
  maplist({Out,Id1}/[Id2]>>gv_edge(Out, Id1, Id2, [label("hasCrawl")]), Id2s),
  maplist(seed2gv_hash(Out), Hash2s).
% archive
seed2gv_dict(Out, Dict) :-
  Hash1{
    http: Dicts1,
    children: Hash2s,
    newline: Newline,
    number_of_bytes: N1,
    number_of_chars: N2,
    number_of_lines: N3,
    status: Status,
    timestamp: Begin-End
  } :< Dict, !,
  atomic_concat(n, Hash1, Id1),
  reverse(Dicts1, Dicts2),
  seed2gv_http(Out, Id1, Dicts2),
  maplist(
    property_label,
    [
      newline(Newline),
      number_of_bytes(N1),
      number_of_chars(N2),
      number_of_lines(N3),
      timestamp(Begin,End)
    ],
    Labels
  ),
  maplist(atomic_concat(n), [Hash1|Hash2s], [Id1|Id2s]),
  format(string(Header), "<B>Archive: ~a</B>", [Status]),
  hash_label(Hash1, Hash1Label),
  gv_node(Out, Id1, [label([Header,Hash1Label|Labels]),shape(box)]),
  maplist({Out,Id1}/[Id2]>>gv_edge(Out, Id1, Id2, [label("hasEntry")]), Id2s),
  maplist(seed, Hash2s, Dict2s),
  maplist(seed2gv_dict(Out), Dict2s).
% entry
seed2gv_dict(Out, Dict1) :-
  Hash1{
    clean: Hash2,
    format: Ext,
    newline: Newline,
    number_of_bytes: N1,
    number_of_chars: N2,
    number_of_lines: N3,
    timestamp: Begin-End
  } :< Dict1, !,
  maplist(
    property_label,
    [
      newline(Newline),
      number_of_bytes(N1),
      number_of_chars(N2),
      number_of_lines(N3),
      timestamp(Begin,End)
    ],
    Labels1
  ),
  maplist(atomic_concat(n), [Hash1,Hash2], [Id1,Id2]),
  extension_label(Ext, Label),
  (   dict_get(http, Dict1, Dicts1)
  ->  reverse(Dicts1, Dicts2),
      seed2gv_http(Out, Id1, Dicts2)
  ;   true
  ),
  (   dict_get(archive, Dict1, ArchiveDicts)
  ->  ArchiveDicts = [ArchiveDict,_],
      _{
        filetype: _FileType,
        filters: ArchiveFilters,
        format: ArchiveFormat,
        mtime: MTime,
        name: Entry,
        permissions: _Permissions,
        size: Size
      } :< ArchiveDict,
      format(string(Header), "<B>Archive Entry: ~a</B>", [Entry]),
      maplist(
        property_label,
        [
          compression(ArchiveFilters),
          archive(ArchiveFormat),
          interval(MTime),
          number_of_bytes(Size)
        ],
        Labels2
      ),
      format(string(Label), "RDF format: ~s", [Label]),
      append([Label|Labels1], Labels2, Labels)
  ;   format(string(Header), "<B>Raw Data: ~s</B>", [Label]),
      Labels = Labels1
  ),
  hash_label(Hash1, Hash1Label),
  gv_node(Out, Id1, [label([Header,Hash1Label|Labels]),shape(box)]),
  gv_edge(Out, Id1, Id2, [label("hasClean")]),
  seed2gv_hash(Out, Hash2).
% clean RDF
seed2gv_dict(Out, Dict) :-
  Hash{
    newline: Newline,
    number_of_bytes: N1,
    number_of_chars: N2,
    number_of_lines: N3,
    number_of_quads: N4,
    number_of_triples: N5,
    timestamp: Begin-End
  } :< Dict, !,
  maplist(
    property_label,
    [
      newline(Newline),
      number_of_bytes(N1),
      number_of_chars(N2),
      number_of_lines(N3),
      number_of_quads(N4),
      number_of_triples(N5),
      timestamp(Begin,End)
    ],
    Labels
  ),
  N6 is N4 + N5,
  format(string(Header), "<B>Clean RDF: ~D statements</B>", [N6]),
  atomic_concat(n, Hash, Id),
  hash_label(Hash, HashLabel),
  gv_node(Out, Id, [label([Header,HashLabel|Labels]),shape(box)]). 
seed2gv_dict(_, Dict) :-
  gtrace,
  writeln(Dict).

seed2gv_http(_, _, []) :- !.
seed2gv_http(Out, Id1, [H|T]) :-
  _{
    headers: Headers,
    status: Status,
    uri: Uri,
    version: Version,
    timestamp: Begin-End
  } :< H,
  _{major: Major, minor: Minor} :< Version,
  http_status_reason(Status, Reason),
  format(
    string(Header),
    "<B>HTTP/~d.~d status: ~d (~s)</B>",
    [Major,Minor,Status,Reason]
  ),
  maplist(
    property_label,
    [final_uri(Uri),timestamp(Begin,End)],
    [Label1,Label2]
  ),
  dict_pairs(Headers, Pairs),
  maplist(http_header_label, Pairs, Labels),
  gv_id(H, Id2),
  gv_node(Out, Id2, [label([Header,Label1,Label2|Labels]),shape(box)]),
  gv_edge(Out, Id1, Id2, [label("HTTP")]),
  seed2gv_http(Out, Id2, T).

hash_label(Hash, Label) :-
  format(string(Label), "~a", [Hash]).

property_label(archive(Format), Label) :-
  format(string(Label), "Archive: ~a", [Format]).
property_label(compression(Filters), Label) :-
  atomics_to_string(Filters, ",", Filter),
  format(string(Label), "Compression: ~s", [Filter]).
property_label(final_uri(Uri), Label) :-
  format(string(Label), "Final URI: ~a", [Uri]).
property_label(interval(N), Label) :-
  format(string(Label), "Crawl interval: ~2f sec.", [N]).
property_label(newline(Newline), Label) :-
  format(string(Label), "Newline: ~a", [Newline]).
property_label(number_of_bytes(N), Label) :-
  format(string(Label), "Bytes: ~D", [N]).
property_label(number_of_chars(N), Label) :-
  format(string(Label), "Characters: ~D", [N]).
property_label(number_of_lines(N), Label) :-
  format(string(Label), "Lines: ~D", [N]).
property_label(number_of_quads(N), Label) :-
  format(string(Label), "Quadruples: ~D", [N]).
property_label(number_of_triples(N), Label) :-
  format(string(Label), "Triples: ~D", [N]).
property_label(processed(Time), Label) :-
  format_time(string(Label), "Last crawl: %a, %d %b %Y %T GMT", Time).
property_label(timestamp(Begin,End), Label) :-
  Duration is End - Begin,
  format(string(Label), "Duration: ~2f sec.", [Duration]).

error_label(error(http_status(Status)), Label) :- !,
  format(string(Label), "HTTP status code ~d", [Status]).
error_label(error(socket_error(Msg),_), Label) :- !,
  format(string(Label), "Socket error: ~a", [Msg]).
error_label(E, _Label) :-
  gtrace,
  writeln(E).

http_header_label(Name1-Values, Label) :-
  http_header_name_label(Name1, Name2),
  atomics_to_string(Values, "; ", Value),
  format(string(Label), "~s: ~w", [Name2,Value]).

bool_string(false, "❌").
bool_string(true, "✓").
