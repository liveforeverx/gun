%% Copyright (c) 2016-2019, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(gun_http2).

-export([check_options/1]).
-export([name/0]).
-export([init/4]).
-export([handle/4]).
-export([close/2]).
-export([keepalive/1]).
-export([headers/10]).
-export([request/11]).
-export([data/7]).
-export([cancel/3]).
-export([stream_info/2]).
-export([down/1]).

-record(stream, {
	id = undefined :: cow_http2:streamid(),

	%% Reference used by the user of Gun to refer to this stream.
	ref :: reference(),

	%% Process to send messages to.
	reply_to :: pid(),

	%% Content handlers state.
	handler_state :: undefined | gun_content_handler:state()
}).

-record(http2_state, {
	owner :: pid(),
	socket :: inet:socket() | ssl:sslsocket(),
	transport :: module(),
	opts = #{} :: map(), %% @todo
	content_handlers :: gun_content_handler:opt(),
	buffer = <<>> :: binary(),

	%% HTTP/2 state machine.
	http2_machine :: cow_http2_machine:http2_machine(),

	%% Currently active HTTP/2 streams. Streams may be initiated either
	%% by the client or by the server through PUSH_PROMISE frames.
	streams = [] :: [#stream{}]
}).

check_options(Opts) ->
	do_check_options(maps:to_list(Opts)).

do_check_options([]) ->
	ok;
do_check_options([Opt={content_handlers, Handlers}|Opts]) ->
	case gun_content_handler:check_option(Handlers) of
		ok -> do_check_options(Opts);
		error -> {error, {options, {http2, Opt}}}
	end;
do_check_options([{keepalive, infinity}|Opts]) ->
	do_check_options(Opts);
do_check_options([{keepalive, K}|Opts]) when is_integer(K), K > 0 ->
	do_check_options(Opts);
do_check_options([Opt|_]) ->
	{error, {options, {http2, Opt}}}.

name() -> http2.

init(Owner, Socket, Transport, Opts) ->
	{ok, Preface, HTTP2Machine} = cow_http2_machine:init(client, Opts),
	Handlers = maps:get(content_handlers, Opts, [gun_data_h]),
	%% @todo Better validate the preface being received.
	State = #http2_state{owner=Owner, socket=Socket,
		transport=Transport, opts=Opts, content_handlers=Handlers,
		http2_machine=HTTP2Machine},
	Transport:send(Socket, Preface),
	State.

handle(Data, State=#http2_state{buffer=Buffer}, EvHandler, EvHandlerState) ->
	parse(<< Buffer/binary, Data/binary >>, State#http2_state{buffer= <<>>},
		EvHandler, EvHandlerState).

parse(Data, State0=#http2_state{http2_machine=HTTP2Machine}, EvHandler, EvHandlerState0) ->
	MaxFrameSize = cow_http2_machine:get_local_setting(max_frame_size, HTTP2Machine),
	case cow_http2:parse(Data, MaxFrameSize) of
		{ok, Frame, Rest} ->
			case frame(State0, Frame, EvHandler, EvHandlerState0) of
				Close = {close, _} -> Close;
				{State, EvHandlerState} -> parse(Rest, State, EvHandler, EvHandlerState)
			end;
		{ignore, Rest} ->
			case ignored_frame(State0) of
				close -> {close, EvHandlerState0};
				State -> parse(Rest, State, EvHandler, EvHandlerState0)
			end;
		{stream_error, StreamID, Reason, Human, Rest} ->
			parse(Rest, reset_stream(State0, StreamID, {stream_error, Reason, Human}),
				EvHandler, EvHandlerState0);
		Error = {connection_error, _, _} ->
			{terminate(State0, Error), EvHandlerState0};
		more ->
			{{state, State0#http2_state{buffer=Data}}, EvHandlerState0}
	end.

%% Frames received.

frame(State=#http2_state{http2_machine=HTTP2Machine0}, Frame, EvHandler, EvHandlerState0) ->
	EvHandlerState = if
		is_tuple(Frame) andalso element(1, Frame) =:= headers ->
			EvStreamID = element(2, Frame),
			case cow_http2_machine:get_stream_remote_state(EvStreamID, HTTP2Machine0) of
				{ok, idle} ->
					#stream{ref=StreamRef, reply_to=ReplyTo} = get_stream_by_id(State, EvStreamID),
					EvHandler:response_start(#{
						stream_ref => StreamRef,
						reply_to => ReplyTo
					}, EvHandlerState0);
				%% Trailers or invalid header frame.
				_ ->
					EvHandlerState0
			end;
		true ->
			EvHandlerState0
	end,
	case cow_http2_machine:frame(Frame, HTTP2Machine0) of
		{ok, HTTP2Machine} ->
			{maybe_ack(State#http2_state{http2_machine=HTTP2Machine}, Frame),
				EvHandlerState};
		{ok, {data, StreamID, IsFin, Data}, HTTP2Machine} ->
			data_frame(State#http2_state{http2_machine=HTTP2Machine}, StreamID, IsFin, Data,
				EvHandler, EvHandlerState);
		{ok, {headers, StreamID, IsFin, Headers, PseudoHeaders, BodyLen}, HTTP2Machine} ->
			headers_frame(State#http2_state{http2_machine=HTTP2Machine},
				StreamID, IsFin, Headers, PseudoHeaders, BodyLen,
				EvHandler, EvHandlerState);
		{ok, {trailers, StreamID, Trailers}, HTTP2Machine} ->
			trailers_frame(State#http2_state{http2_machine=HTTP2Machine},
				StreamID, Trailers, EvHandler, EvHandlerState);
		{ok, {rst_stream, StreamID, Reason}, HTTP2Machine} ->
			{rst_stream_frame(State#http2_state{http2_machine=HTTP2Machine}, StreamID, Reason),
				EvHandlerState};
		{ok, {push_promise, StreamID, PromisedStreamID, Headers, PseudoHeaders}, HTTP2Machine} ->
			{push_promise_frame(State#http2_state{http2_machine=HTTP2Machine},
				StreamID, PromisedStreamID, Headers, PseudoHeaders),
				EvHandlerState};
		{ok, Frame={goaway, _StreamID, _Reason, _Data}, HTTP2Machine} ->
			{terminate(State#http2_state{http2_machine=HTTP2Machine},
				{stop, Frame, 'Server is going away.'}),
				EvHandlerState};
		{send, SendData, HTTP2Machine} ->
			send_data(maybe_ack(State#http2_state{http2_machine=HTTP2Machine}, Frame), SendData,
				EvHandler, EvHandlerState);
		{error, {stream_error, StreamID, Reason, Human}, HTTP2Machine} ->
			{reset_stream(State#http2_state{http2_machine=HTTP2Machine},
				StreamID, {stream_error, Reason, Human}),
				EvHandlerState};
		{error, Error={connection_error, _, _}, HTTP2Machine} ->
			{terminate(State#http2_state{http2_machine=HTTP2Machine}, Error),
				EvHandlerState}
	end.

maybe_ack(State=#http2_state{socket=Socket, transport=Transport}, Frame) ->
	case Frame of
		{settings, _} -> Transport:send(Socket, cow_http2:settings_ack());
		{ping, Opaque} -> Transport:send(Socket, cow_http2:ping_ack(Opaque));
		_ -> ok
	end,
	State.

data_frame(State=#http2_state{socket=Socket, transport=Transport,
		http2_machine=HTTP2Machine0}, StreamID, IsFin, Data,
		EvHandler, EvHandlerState0) ->
	Stream = #stream{ref=StreamRef, reply_to=ReplyTo,
		handler_state=Handlers0} = get_stream_by_id(State, StreamID),
	Handlers = gun_content_handler:handle(IsFin, Data, Handlers0),
	Size = byte_size(Data),
	{HTTP2Machine, EvHandlerState} = case Size of
		%% We do not send a WINDOW_UPDATE if the DATA frame was of size 0.
		0 when IsFin =:= fin ->
			EvHandlerState1 = EvHandler:response_end(#{
				stream_ref => StreamRef,
				reply_to => ReplyTo
			}, EvHandlerState0),
			{HTTP2Machine0, EvHandlerState1};
		0 ->
			{HTTP2Machine0, EvHandlerState0};
		_ ->
			Transport:send(Socket, cow_http2:window_update(Size)),
			HTTP2Machine1 = cow_http2_machine:update_window(Size, HTTP2Machine0),
			%% We do not send a stream WINDOW_UPDATE if this was the last DATA frame.
			case IsFin of
				nofin ->
					Transport:send(Socket, cow_http2:window_update(StreamID, Size)),
					{cow_http2_machine:update_window(StreamID, Size, HTTP2Machine1),
						EvHandlerState0};
				fin ->
					EvHandlerState1 = EvHandler:response_end(#{
						stream_ref => StreamRef,
						reply_to => ReplyTo
					}, EvHandlerState0),
					{HTTP2Machine1, EvHandlerState1}
			end
	end,
	{maybe_delete_stream(store_stream(State#http2_state{http2_machine=HTTP2Machine},
		Stream#stream{handler_state=Handlers}), StreamID, remote, IsFin),
		EvHandlerState}.

headers_frame(State=#http2_state{content_handlers=Handlers0},
		StreamID, IsFin, Headers, PseudoHeaders, _BodyLen,
		EvHandler, EvHandlerState0) ->
	Stream = #stream{ref=StreamRef, reply_to=ReplyTo} = get_stream_by_id(State, StreamID),
	case PseudoHeaders of
		#{status := Status} when Status >= 100, Status =< 199 ->
			ReplyTo ! {gun_inform, self(), StreamRef, Status, Headers},
			EvHandlerState = EvHandler:response_inform(#{
				stream_ref => StreamRef,
				reply_to => ReplyTo,
				status => Status,
				headers => Headers
			}, EvHandlerState0),
			{State, EvHandlerState};
		#{status := Status} ->
			ReplyTo ! {gun_response, self(), StreamRef, IsFin, Status, Headers},
			EvHandlerState1 = EvHandler:response_headers(#{
				stream_ref => StreamRef,
				reply_to => ReplyTo,
				status => Status,
				headers => Headers
			}, EvHandlerState0),
			{Handlers, EvHandlerState} = case IsFin of
				fin ->
					EvHandlerState2 = EvHandler:response_end(#{
						stream_ref => StreamRef,
						reply_to => ReplyTo
					}, EvHandlerState1),
					{undefined, EvHandlerState2};
				nofin ->
					{gun_content_handler:init(ReplyTo, StreamRef,
						Status, Headers, Handlers0), EvHandlerState1}
			end,
			{maybe_delete_stream(store_stream(State, Stream#stream{handler_state=Handlers}),
				StreamID, remote, IsFin),
				EvHandlerState}
	end.

trailers_frame(State, StreamID, Trailers, EvHandler, EvHandlerState0) ->
	#stream{ref=StreamRef, reply_to=ReplyTo} = get_stream_by_id(State, StreamID),
	%% @todo We probably want to pass this to gun_content_handler?
	ReplyTo ! {gun_trailers, self(), StreamRef, Trailers},
	ResponseEvent = #{
		stream_ref => StreamRef,
		reply_to => ReplyTo
	},
	EvHandlerState1 = EvHandler:response_trailers(ResponseEvent#{headers => Trailers}, EvHandlerState0),
	EvHandlerState = EvHandler:response_end(ResponseEvent, EvHandlerState1),
	{maybe_delete_stream(State, StreamID, remote, fin), EvHandlerState}.

rst_stream_frame(State=#http2_state{streams=Streams0}, StreamID, Reason) ->
	case lists:keytake(StreamID, #stream.id, Streams0) of
		{value, #stream{ref=StreamRef, reply_to=ReplyTo}, Streams} ->
			ReplyTo ! {gun_error, self(), StreamRef,
				{stream_error, Reason, 'Stream reset by server.'}},
			State#http2_state{streams=Streams};
		false ->
			State
	end.

push_promise_frame(State=#http2_state{streams=Streams},
		StreamID, PromisedStreamID, Headers, #{
			method := Method, scheme := Scheme,
			authority := Authority, path := Path}) ->
	#stream{ref=StreamRef, reply_to=ReplyTo} = get_stream_by_id(State, StreamID),
	PromisedStreamRef = make_ref(),
	ReplyTo ! {gun_push, self(), StreamRef, PromisedStreamRef, Method,
		iolist_to_binary([Scheme, <<"://">>, Authority, Path]), Headers},
	NewStream = #stream{id=PromisedStreamID, ref=PromisedStreamRef, reply_to=ReplyTo},
	State#http2_state{streams=[NewStream|Streams]}.

ignored_frame(State=#http2_state{http2_machine=HTTP2Machine0}) ->
	case cow_http2_machine:ignored_frame(HTTP2Machine0) of
		{ok, HTTP2Machine} ->
			State#http2_state{http2_machine=HTTP2Machine};
		{error, Error={connection_error, _, _}, HTTP2Machine} ->
			terminate(State#http2_state{http2_machine=HTTP2Machine}, Error)
	end.

%% @todo Use Reason.
close(_, #http2_state{streams=Streams}) ->
	close_streams(Streams).

close_streams([]) ->
	ok;
close_streams([#stream{ref=StreamRef, reply_to=ReplyTo}|Tail]) ->
	ReplyTo ! {gun_error, self(), StreamRef, {closed,
		"The connection was lost."}},
	close_streams(Tail).

keepalive(State=#http2_state{socket=Socket, transport=Transport}) ->
	Transport:send(Socket, cow_http2:ping(0)),
	State.

headers(State=#http2_state{socket=Socket, transport=Transport,
		http2_machine=HTTP2Machine0, streams=Streams},
		StreamRef, ReplyTo, Method, Host, Port, Path, Headers0,
		EvHandler, EvHandlerState0) ->
	{ok, StreamID, HTTP2Machine1} = cow_http2_machine:init_stream(
		iolist_to_binary(Method), HTTP2Machine0),
	{ok, PseudoHeaders, Headers} = prepare_headers(State, Method, Host, Port, Path, Headers0),
	RequestEvent = #{
		stream_ref => StreamRef,
		reply_to => ReplyTo,
		function => ?FUNCTION_NAME,
		method => Method,
		authority => maps:get(authority, PseudoHeaders),
		path => Path,
		headers => Headers
	},
	EvHandlerState1 = EvHandler:request_start(RequestEvent, EvHandlerState0),
	{ok, IsFin, HeaderBlock, HTTP2Machine} = cow_http2_machine:prepare_headers(
		StreamID, HTTP2Machine1, nofin, PseudoHeaders, Headers),
	Transport:send(Socket, cow_http2:headers(StreamID, IsFin, HeaderBlock)),
	EvHandlerState = EvHandler:request_headers(RequestEvent, EvHandlerState1),
	Stream = #stream{id=StreamID, ref=StreamRef, reply_to=ReplyTo},
	{State#http2_state{http2_machine=HTTP2Machine, streams=[Stream|Streams]},
		EvHandlerState}.

request(State=#http2_state{socket=Socket, transport=Transport,
		http2_machine=HTTP2Machine0, streams=Streams},
		StreamRef, ReplyTo, Method, Host, Port, Path, Headers0, Body,
		EvHandler, EvHandlerState0) ->
	Headers1 = lists:keystore(<<"content-length">>, 1, Headers0,
		{<<"content-length">>, integer_to_binary(iolist_size(Body))}),
	{ok, StreamID, HTTP2Machine1} = cow_http2_machine:init_stream(
		iolist_to_binary(Method), HTTP2Machine0),
	{ok, PseudoHeaders, Headers} = prepare_headers(State, Method, Host, Port, Path, Headers1),
	RequestEvent = #{
		stream_ref => StreamRef,
		reply_to => ReplyTo,
		function => ?FUNCTION_NAME,
		method => Method,
		authority => maps:get(authority, PseudoHeaders),
		path => Path,
		headers => Headers
	},
	EvHandlerState1 = EvHandler:request_start(RequestEvent, EvHandlerState0),
	{ok, IsFin, HeaderBlock, HTTP2Machine} = cow_http2_machine:prepare_headers(
		StreamID, HTTP2Machine1, nofin, PseudoHeaders, Headers),
	Transport:send(Socket, cow_http2:headers(StreamID, IsFin, HeaderBlock)),
	EvHandlerState = EvHandler:request_headers(RequestEvent, EvHandlerState1),
	Stream = #stream{id=StreamID, ref=StreamRef, reply_to=ReplyTo},
	maybe_send_data(State#http2_state{http2_machine=HTTP2Machine,
		streams=[Stream|Streams]}, StreamID, fin, Body,
		EvHandler, EvHandlerState).

prepare_headers(#http2_state{transport=Transport}, Method, Host0, Port, Path, Headers0) ->
	Authority = case lists:keyfind(<<"host">>, 1, Headers0) of
		{_, Host} -> Host;
		_ -> gun_http:host_header(Transport, Host0, Port)
	end,
	%% @todo We also must remove any header found in the connection header.
	Headers =
		lists:keydelete(<<"host">>, 1,
		lists:keydelete(<<"connection">>, 1,
		lists:keydelete(<<"keep-alive">>, 1,
		lists:keydelete(<<"proxy-connection">>, 1,
		lists:keydelete(<<"transfer-encoding">>, 1,
		lists:keydelete(<<"upgrade">>, 1, Headers0)))))),
	PseudoHeaders = #{
		method => Method,
		scheme => case Transport of
			gun_tls -> <<"https">>;
			gun_tls_proxy -> <<"https">>;
			gun_tcp -> <<"http">>
		end,
		authority => Authority,
		path => Path
	},
	{ok, PseudoHeaders, Headers}.

data(State=#http2_state{http2_machine=HTTP2Machine}, StreamRef, ReplyTo, IsFin, Data,
		EvHandler, EvHandlerState) ->
	case get_stream_by_ref(State, StreamRef) of
		#stream{id=StreamID} ->
			case cow_http2_machine:get_stream_local_state(StreamID, HTTP2Machine) of
				{ok, fin, _} ->
					{error_stream_closed(State, StreamRef, ReplyTo), EvHandlerState};
				{ok, _, fin} ->
					{error_stream_closed(State, StreamRef, ReplyTo), EvHandlerState};
				{ok, _, _} ->
					maybe_send_data(State, StreamID, IsFin, Data, EvHandler, EvHandlerState)
			end;
		false ->
			{error_stream_not_found(State, StreamRef, ReplyTo), EvHandlerState}
	end.

maybe_send_data(State=#http2_state{http2_machine=HTTP2Machine0}, StreamID, IsFin, Data0,
		EvHandler, EvHandlerState) ->
	Data = case is_tuple(Data0) of
		false -> {data, Data0};
		true -> Data0
	end,
	case cow_http2_machine:send_or_queue_data(StreamID, HTTP2Machine0, IsFin, Data) of
		{ok, HTTP2Machine} ->
			{State#http2_state{http2_machine=HTTP2Machine}, EvHandlerState};
		{send, SendData, HTTP2Machine} ->
			send_data(State#http2_state{http2_machine=HTTP2Machine}, SendData,
				EvHandler, EvHandlerState)
	end.

send_data(State, [], _, EvHandlerState) ->
	{State, EvHandlerState};
send_data(State0, [{StreamID, IsFin, SendData}|Tail], EvHandler, EvHandlerState0) ->
	{State, EvHandlerState} = send_data(State0, StreamID, IsFin, SendData, EvHandler, EvHandlerState0),
	send_data(State, Tail, EvHandler, EvHandlerState).

send_data(State0, StreamID, IsFin, [Data], EvHandler, EvHandlerState0) ->
	State = send_data_frame(State0, StreamID, IsFin, Data),
	EvHandlerState = case IsFin of
		nofin ->
			EvHandlerState0;
		fin ->
			#stream{ref=StreamRef, reply_to=ReplyTo} = get_stream_by_id(State, StreamID),
			RequestEndEvent = #{
				stream_ref => StreamRef,
				reply_to => ReplyTo
			},
			EvHandler:request_end(RequestEndEvent, EvHandlerState0)
	end,
	{maybe_delete_stream(State, StreamID, local, IsFin), EvHandlerState};
send_data(State0, StreamID, IsFin, [Data|Tail], EvHandler, EvHandlerState) ->
	State = send_data_frame(State0, StreamID, nofin, Data),
	send_data(State, StreamID, IsFin, Tail, EvHandler, EvHandlerState).

send_data_frame(State=#http2_state{socket=Socket, transport=Transport},
		StreamID, IsFin, {data, Data}) ->
	Transport:send(Socket, cow_http2:data(StreamID, IsFin, Data)),
	State;
%% @todo Uncomment this once sendfile is supported.
%send_data_frame(State=#http2_state{socket=Socket, transport=Transport},
%		StreamID, IsFin, {sendfile, Offset, Bytes, Path}) ->
%	Transport:send(Socket, cow_http2:data_header(StreamID, IsFin, Bytes)),
%	Transport:sendfile(Socket, Path, Offset, Bytes),
%	State;
%% The stream is terminated in cow_http2_machine:prepare_trailers.
send_data_frame(State=#http2_state{socket=Socket, transport=Transport,
		http2_machine=HTTP2Machine0}, StreamID, nofin, {trailers, Trailers}) ->
	{ok, HeaderBlock, HTTP2Machine}
		= cow_http2_machine:prepare_trailers(StreamID, HTTP2Machine0, Trailers),
	Transport:send(Socket, cow_http2:headers(StreamID, fin, HeaderBlock)),
	State#http2_state{http2_machine=HTTP2Machine}.

reset_stream(State=#http2_state{socket=Socket, transport=Transport,
		streams=Streams0}, StreamID, StreamError={stream_error, Reason, _}) ->
	Transport:send(Socket, cow_http2:rst_stream(StreamID, Reason)),
	case lists:keytake(StreamID, #stream.id, Streams0) of
		{value, #stream{ref=StreamRef, reply_to=ReplyTo}, Streams} ->
			ReplyTo ! {gun_error, self(), StreamRef, StreamError},
			State#http2_state{streams=Streams};
		false ->
			State
	end.

cancel(State=#http2_state{socket=Socket, transport=Transport,
		http2_machine=HTTP2Machine0}, StreamRef, ReplyTo) ->
	case get_stream_by_ref(State, StreamRef) of
		#stream{id=StreamID} ->
			{ok, HTTP2Machine} = cow_http2_machine:reset_stream(StreamID, HTTP2Machine0),
			Transport:send(Socket, cow_http2:rst_stream(StreamID, cancel)),
			delete_stream(State#http2_state{http2_machine=HTTP2Machine}, StreamID);
		false ->
			error_stream_not_found(State, StreamRef, ReplyTo)
	end.

stream_info(State, StreamRef) ->
	case get_stream_by_ref(State, StreamRef) of
		#stream{reply_to=ReplyTo} ->
			{ok, #{
				ref => StreamRef,
				reply_to => ReplyTo,
				state => running
			}};
		false ->
			{ok, undefined}
	end.

%% @todo Add unprocessed streams when GOAWAY handling is done.
down(#http2_state{streams=Streams}) ->
	KilledStreams = [Ref || #stream{ref=Ref} <- Streams],
	{KilledStreams, []}.

terminate(#http2_state{socket=Socket, transport=Transport,
		http2_machine=HTTP2Machine, streams=Streams}, Reason) ->
	%% The connection is going away either at the request of the server,
	%% or because an error occurred in the protocol. Inform the streams.
	%% @todo We should not send duplicate messages to processes.
	%% @todo We should probably also inform the owner process.

	%% @todo Somehow streams aren't removed on receiving a response.
	_ = [ReplyTo ! {gun_error, self(), Reason} || #stream{reply_to=ReplyTo} <- Streams],
	Transport:send(Socket, cow_http2:goaway(
		cow_http2_machine:get_last_streamid(HTTP2Machine),
		terminate_reason(Reason), <<>>)),
	close.

terminate_reason({connection_error, Reason, _}) -> Reason;
terminate_reason({stop, _, _}) -> no_error.

%% Stream functions.

error_stream_closed(State, StreamRef, ReplyTo) ->
	ReplyTo ! {gun_error, self(), StreamRef, {badstate,
		"The stream has already been closed."}},
	State.

error_stream_not_found(State, StreamRef, ReplyTo) ->
	ReplyTo ! {gun_error, self(), StreamRef, {badstate,
		"The stream cannot be found."}},
	State.

%% Streams.
%% @todo probably change order of args and have state first? Yes.

get_stream_by_id(#http2_state{streams=Streams}, StreamID) ->
	lists:keyfind(StreamID, #stream.id, Streams).

get_stream_by_ref(#http2_state{streams=Streams}, StreamRef) ->
	lists:keyfind(StreamRef, #stream.ref, Streams).

store_stream(State=#http2_state{streams=Streams0}, Stream=#stream{id=StreamID}) ->
	Streams = lists:keyreplace(StreamID, #stream.id, Streams0, Stream),
	State#http2_state{streams=Streams}.

maybe_delete_stream(State=#http2_state{http2_machine=HTTP2Machine}, StreamID, local, fin) ->
	case cow_http2_machine:get_stream_remote_state(StreamID, HTTP2Machine) of
		{ok, fin} -> delete_stream(State, StreamID);
		{error, closed} -> delete_stream(State, StreamID);
		_ -> State
	end;
maybe_delete_stream(State=#http2_state{http2_machine=HTTP2Machine}, StreamID, remote, fin) ->
	case cow_http2_machine:get_stream_local_state(StreamID, HTTP2Machine) of
		{ok, fin, _} -> delete_stream(State, StreamID);
		{error, closed} -> delete_stream(State, StreamID);
		_ -> State
	end;
maybe_delete_stream(State, _, _, _) ->
	State.

delete_stream(State=#http2_state{streams=Streams}, StreamID) ->
	Streams2 = lists:keydelete(StreamID, #stream.id, Streams),
	State#http2_state{streams=Streams2}.
