:- module(
  lwm_clean,
  [
    lwm_clean_loop/0
  ]
).

/** <module> LOD Washing Machine: cleaning

The cleaning process performed by the LOD Washing Machine.

@author Wouter Beek
@version 2014/03-2014/06
*/

:- use_module(library(aggregate)).
:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(pairs)).
:- use_module(library(semweb/rdf_db)).
:- use_module(library(zlib)).

:- use_module(http(http_download)).
:- use_module(os(archive_ext)).
:- use_module(os(file_ext)).
:- use_module(pl(pl_log)).
:- use_module(void(void_db)). % XML namespace.

:- use_module(plRdf_ser(rdf_detect)).
:- use_module(plRdf_ser(rdf_ntriples_write)).
:- use_module(plRdf_term(rdf_literal)).

:- use_module(lwm(lod_basket)).
:- use_module(lwm(lwm_generics)).
:- use_module(lwm(lwm_store_triple)).
:- use_module(lwm(noRdf_store)).



lwm_clean_loop:-
  % Pick a new source to process.
  catch(pick_unpacked(Md5), E, writeln(E)),

  % Process the URL we picked.
  lwm_clean(Md5),

  % Intermittent loop.
  lwm_clean_loop.
% Done for now. Check whether there are new jobs in one seconds.
lwm_clean_loop:-
  sleep(1),
  lwm_clean_loop.


%! lwm_clean(+Md5:atom) is det.

lwm_clean(Md5):-
  print_message(informational, start(clean,Md5)),

  run_collect_messages(
    clean_md5(Md5),
    Status,
    Messages
  ),
  store_status(Md5, Status),
  maplist(store_message(Md5), Messages),

  store_end_clean(Md5),
  print_message(informational, end(clean,Md5,Status,Messages)).


%! clean_md5(+Md5:atom) is det.

clean_md5(Md5):-
  % Construct the file name belonging to the given MD5.
  md5_to_dir(Md5, Md5Dir),
  directory_file_path(Md5Dir, dirty, File),
  
  % Retrieve the content type that was previously determined.
  lwm_sparql_select([lwm], [content_type],
      [rdf(var(md5res),lwm:md5,literal(xsd:string,Md5)),
       rdf(var(md5res),lwm:content_type,var(content_type))],
      [[Literal]], [limit(1)]),
  rdf_literal(Literal, ContentType, _),
  
  % Clean the data document in an RDF transaction.
  setup_call_cleanup(
    open(File, read, Read),
    (
      rdf_transaction(
        clean_datastream(Md5, File, Read, ContentType, VoidUrls),
        _,
        [snapshot(true)]
      ),
      store_stream(Md5,Read)
    ),
    close(Read)
  ),
  
  % Add the new VoID URLs to the LOD Basket.
  maplist(add_to_basket, VoidUrls).


%! clean_datastream(
%!   +Md5:atom,
%!   +File:atom,
%!   +Read:blob,
%!   +ContentType:atom,
%!   -VoidUrls:ordset(url)
%! ) is det.

clean_datastream(Md5, File, Read, ContentType, VoidUrls):-
  % Store the file extension.
  file_name_extensions(_, FileExtensions, base),
  atomic_list_concat(FileExtensions, '.', FileExtension),
  store_triple(lwm-Md5, lwm-file_extension,
      literal(type(xsd-string,FileExtension))),

  % Guess the RDF serialization format,
  % using the content type and the file extension as suggestions.
  rdf_guess_format(Md5, Read, FileExtension, ContentType, Format),
  store_triple(lwm-Md5, lwm-serialization_format,
      literal(type(xsd-string,Format))),

  % Load all triples by parsing the data document
  % according to the guessed RDF serialization format.
  lwm_base(Md5, Base),
  rdf_load(
    stream(Read),
    [base_uri(Base),format(Format),register_namespaces(false)]
  ),

  % In between loading and saving the data,
  % we count the number of triples, including the number of duplicates.
  aggregate_all(
    count,
    rdf(_, _, _, _),
    TIn
  ),

  % Save the data in a cleaned format.
  save_data_to_file(Md5, File, TOut),

  % Store statistics about the number of (duplicate) triples.
  store_number_of_triples(Md5, TIn, TOut),

  % Make sure any VoID datadumps are added to the LOD Basket.
  find_void_datasets(VoidUrls).



% Helpers

%! find_void_datasets(-VoidUrls:ordset(url)) is det.

find_void_datasets(Urls):-
  aggregate_all(
    set(Url),
    (
      rdf(_, void:dataDump, Url),
      % @tbd Create a shortcut for this: only a single SPARQL query,
      % matching `lwm:added`.
      \+ cleaned(Md5),
      \+ pending(Md5)
    ),
    Urls
  ),
  print_message(informational, found_void(Urls)).


%! rdf_content_type(?ContentType:atom, ?Format:atom) is nondet.

rdf_content_type('text/rdf',      xml).
rdf_content_type('text/xml',      xml).
rdf_content_type('text/rdf+xml',    xml).
rdf_content_type('application/rdf+xml',    xml).
rdf_content_type('application/x-turtle',  turtle).
rdf_content_type('application/turtle',    turtle).
rdf_content_type('application/trig',    trig).
rdf_content_type('application/n-triples', ntriples).
rdf_content_type('application/n-quads',   nquads).
rdf_content_type('text/turtle',      turtle).
rdf_content_type('text/rdf+n3',      turtle).  % Bit dubious
rdf_content_type('text/html',      html).
rdf_content_type('application/xhtml+xml', xhtml).


%! rdf_guess_format(
%!   +Md5:atom,
%!   +Read:blob,
%!   +FileExtension:atom,
%!   +ContentType:atom,
%!   -Format:atom
%! ) is semidet.

rdf_guess_format(_, Read, FileExtension, _, Format):-
  rdf_db:rdf_file_type(FileExtension, SuggestedFormat),
  rdf_guess_format(Read, Format, [format(SuggestedFormat)]), !.
rdf_guess_format(_, Read, _, ContentType, Format):-
  rdf_content_type(ContentType, SuggestedFormat),
  rdf_guess_format(Read, Format, [format(SuggestedFormat)]), !.
rdf_guess_format(Md5, _, _, _, _):-
  throw(error(no_rdf(Md5))).


%! save_data_to_file(+Md5:atom, +File:atom, -NumberOfTriples:nonneg) is det.

save_data_to_file(Md5, File, NumberOfTriples):-
  file_directory_name(File, Dir),
  directory_file_path(Dir, 'clean.nt.gz', Path),
  lwm_bnode_base(Md5, BNodeBase),
  setup_call_cleanup(
    gzopen(Path, write, Write),
    rdf_ntriples_write(
      Write,
      [bnode_base(BNodeBase),number_of_triples(NumberOfTriples)]
    ),
    close(Write)
  ).



% Messages

:- multifile(prolog:message//1).

prolog:message(found_void([])) --> !, [].
prolog:message(found_void([H|T])) -->
  ['[VoID] Found: ',H,nl],
  prolog:message(found_void(T)).
