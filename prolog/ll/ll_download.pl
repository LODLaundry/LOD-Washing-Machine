:- module(ll_download, [ll_download/0,ll_download/1]).

/** <module> LOD Laundromat: Download

@author Wouter Beek
@version 2017-2018
*/

:- use_module(library(error)).

:- use_module(library(debug_ext)).
:- use_module(library(dict)).
:- use_module(library(hash_ext)).
:- use_module(library(http/http_client2)).
:- use_module(library(ll/ll_generics)).
:- use_module(library(ll/ll_metadata)).
:- use_module(library(semweb/rdf_media_type)).

ll_download :-
  % precondition
  (   debugging(ll(offline))
  ->  true
  ;   start_task(stale, Hash, State),
      ll_download(Hash, State.uri, State)
  ).

ll_download(Uri) :-
  md5(Uri, Hash),
  ll_download(Hash, Uri, _{}).

ll_download(Hash, Uri, State1) :-
  % preparation
  indent_debug(1, ll(task,download), "> downloading ~a ~a", [Hash,Uri]),
  write_meta_now(Hash, downloadBegin),
  write_meta_quad(Hash, uri, uri(Uri)),
  % operation
  catch(download_uri(Hash, Uri, State1-State2), E, true),
  % postcondition
  write_meta_now(Hash, downloadEnd),
  handle_status(Hash, E, downloaded, State2),
  (debugging(ll(offline)) -> gtrace ; true),
  indent_debug(-1, ll(task,download), "< downloaded ~a ~a", [Hash,Uri]).

download_uri(Hash, Uri, State1-State3) :-
  hash_file(Hash, compressed, File),
  setup_call_cleanup(
    open(File, write, Out, [type(binary)]),
    download_stream(Hash, Uri, Out, MediaType, Status, FinalUri),
    close_metadata(Hash, downloadWritten, Out)
  ),
  % End task or finish with an error, depending on the HTTP status
  % code.
  (   between(200, 299, Status)
  ->  dict_put(base_uri, State1, FinalUri, State2),
      (   var(MediaType)
      ->  State3 = State2
      ;   dict_put(media_type, State2, MediaType, State3)
      )
  ;   % cleanup
      hash_file(Hash, compressed, File),
      delete_file(File),
      (   % Correct HTTP error status code
          between(400, 599, Status)
      ->  throw(error(http_error(status,Status),ll_download))
      ;   % Incorrect HTTP status code
          type_error(http_status, Status)
      ),
      State3 = State1
  ).

download_stream(Hash, Uri, Out, MediaType, Status, FinalUri) :-
  findall(RdfMediaType, rdf_media_type(RdfMediaType), RdfMediaTypes),
  Options = [accept(RdfMediaTypes),
             final_uri(FinalUri),
             maximum_number_of_hops(10),
             metadata(HttpMetas),
             status(Status)],
  http_open2(Uri, In, Options),
  ignore(http_metadata_content_type(HttpMetas, MediaType)),
  write_meta_http(Hash, HttpMetas),
  (   between(200, 299, Status)
  ->  call_cleanup(
        copy_stream_data(In, Out),
        close_metadata(Hash, downloadRead, In)
      )
  ;   call_cleanup(
        read_string(In, 1 000, Body),
        close(In)
      ),
      throw(error(http_error(status,Status,Body,FinalUri),download_stream/6))
  ).
